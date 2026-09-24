import Foundation
import os
import Observation
import SwiftData

/// Records a meeting: live transcription, speaker diarization, and persistence.
///
/// Distinct from `RecordingCoordinator`, which handles dictation. Dictation is short,
/// disposable and ends by putting text somewhere. A meeting is long, is kept, and ends
/// by being written to the store.
@MainActor
@Observable
final class MeetingRecorder {

    enum State: Equatable {
        case idle
        /// Loading diarization models, which may need downloading on first use.
        case preparing
        case recording
        /// Capture stopped, meeting still open.
        case paused
        /// Aligning and saving after the user stopped.
        case finishing
    }

    // MARK: - Dependencies

    private let engine: TranscriptionEngine
    private let settings: AppSettings
    private let aiProcessor: AIProcessor

    private let diarizer = MeetingDiarizer()
    private let converter = DiarizationAudioConverter()
    private let systemAudio = SystemAudioCapture()
    private let audioWriter = MeetingAudioWriter()

    // MARK: - Observable State

    #if os(macOS)
    /// The small panel that shows the microphone is still hearing the room.
    private let indicator: MeetingIndicatorController

    /// Feeds it while a meeting runs.
    private var indicatorTicker: Task<Void, Never>?
    #endif

    private(set) var state: State = .idle
    private(set) var activeMeeting: Meeting?
    private(set) var lastError: String?

    /// Whether diarization is running. False means the meeting is still transcribed,
    /// just without speaker labels.
    private(set) var diarizationActive = false

    /// Whether this meeting is recording system playback as well as the microphone.
    private(set) var systemAudioActive = false

    // MARK: - Session Bookkeeping

    /// Timed runs from every session so far, already shifted onto the meeting clock.
    ///
    /// Stopping the engine resets its own timestamps to zero, so each session's runs
    /// are harvested and offset before the next one starts. Without this a meeting
    /// paused once would attribute its second half against the first half's timeline.
    private var collectedSegments: [TimedTranscriptSegment] = []

    /// Plain transcript accumulated across sessions.
    private var accumulatedTranscript = ""

    /// Where the current session sits on the meeting clock.
    private var sessionOffset: TimeInterval = 0

    /// Audio seconds captured in sessions that have already ended.
    private var completedAudioSeconds: TimeInterval = 0

    /// The start begun by `start()`, while it is still running.
    ///
    /// A quit arriving during "Preparing…" waits on this. Cleaning up the half-built
    /// meeting from outside would hand the start a model the store had dropped.
    private var startTask: Task<Void, Never>?

    /// The save started by `stop()`, while it is still running.
    ///
    /// Quitting can call `stop()` a second time while the first one is mid-save. That
    /// caller waits on this rather than being turned away by the guard, which would
    /// report the meeting written and let the app terminate through the middle of it.
    private var finishTask: Task<Void, Never>?

    /// The pause or resume begun by `pause()` or `resume()`, while it is still running.
    ///
    /// Either one takes a few hundred milliseconds of engine work, and the state does not
    /// change until it is over. Without this, a second click in that window passed the
    /// state guard and ran the same step again: two resumes started the engine twice, and
    /// two pauses harvested the same session twice and doubled every word. A stop or a
    /// quit arriving in that window tore the meeting down underneath the step, which then
    /// finished against a meeting that no longer existed. Pause and resume refuse to begin
    /// while this is set, and stop waits for it.
    ///
    /// Cleared by the task itself as its last act, on the main actor, so a stop waiting on
    /// it never sees it cleared late and never mistakes a finished step for one running.
    private var transitionTask: Task<Void, Never>?

    /// Ordered handoff of captured audio to the diarizer.
    ///
    /// The tap runs on the audio thread and the diarizer is an actor, so the handoff
    /// has to be asynchronous. A task per buffer arrives in whatever order the tasks
    /// were scheduled, which scrambles the 16 kHz stream the clustering reads.
    private var diarizerFeed: AsyncStream<[Float]>.Continuation?
    private var diarizerFeedTask: Task<Void, Never>?

    /// Live text: everything kept so far, plus whatever this session has heard.
    ///
    /// Only this meeting's own session counts. Without the owner check, a dictation
    /// taken during a pause appeared in the meeting window as though it were part of
    /// the meeting, and then vanished on stop, because it was never saved into one.
    var liveTranscript: String {
        let current = engine.owner == .meeting
            ? engine.currentTranscript + engine.volatileText
            : ""
        guard !accumulatedTranscript.isEmpty else { return current }
        guard !current.isEmpty else { return accumulatedTranscript }
        return accumulatedTranscript + " " + current
    }

    /// Audio captured so far, including earlier segments of a paused meeting.
    var recordedSeconds: TimeInterval {
        guard state == .recording, let sessionStartedAt else { return completedAudioSeconds }
        return completedAudioSeconds + Date().timeIntervalSince(sessionStartedAt)
    }

    var isRecording: Bool { state == .recording }
    var isPaused: Bool { state == .paused }

    /// Whether a meeting is open, recording or not.
    ///
    /// Read off `state` alone rather than `activeMeeting`, which stays nil until a
    /// meeting actually records: a quit during "Preparing…" has a row in the store and
    /// possibly an open audio file, and answering false there abandons both.
    var hasActiveMeeting: Bool { state != .idle }

    // MARK: - Initialization

    init(engine: TranscriptionEngine, settings: AppSettings, aiProcessor: AIProcessor) {
        self.engine = engine
        self.settings = settings
        self.aiProcessor = aiProcessor
        #if os(macOS)
        self.indicator = MeetingIndicatorController(settings: settings)
        #endif
    }

    #if os(macOS)
    /// Show the panel and keep it fed for as long as the meeting lasts.
    ///
    /// Twenty a second, like the dictation overlay: the band is drawn from the
    /// microphone and anything slower reads as lag.
    private func startIndicator() {
        guard settings.showMeetingIndicator else { return }
        indicatorTicker?.cancel()

        // The panel's buttons reach back here, so pausing or ending a meeting does not
        // mean going to find the window it belongs to.
        indicator.onPauseOrResume = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.isPaused ? await self.resume() : await self.pause()
            }
        }
        indicator.onStop = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                await self.stop(in: ScribeApp.modelContainer.mainContext)
            }
        }

        indicator.show()
        indicatorTicker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.state != .idle else { return }
                self.indicator.update(
                    spectrum: self.engine.spectrum,
                    seconds: self.recordedSeconds,
                    isPaused: self.isPaused
                )
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func stopIndicator() {
        indicatorTicker?.cancel()
        indicatorTicker = nil
        indicator.hide()
    }
    #endif

    // MARK: - Recording

    /// Begin a meeting, creating and inserting the record up front.
    ///
    /// The `Meeting` exists in the store from the first second, so a crash mid-meeting
    /// leaves a titled, findable record rather than nothing.
    func start(in context: ModelContext) async {
        guard state == .idle else { return }

        // Claimed here, before the diarization models load, because that load takes
        // seconds on a cold start. Left unclaimed, the engine looks free for all of
        // it, and a dictation taken in that window wins the race — the meeting's own
        // start then throws and deletes the meeting it had already saved.
        guard engine.reserve(owner: .meeting) else {
            lastError = "Inscribe is already recording. Finish that first."
            AudioFeedbackService.shared.playIfEnabled(.error, settings: settings)
            return
        }

        state = .preparing

        let task = Task { await self.begin(in: context) }
        startTask = task
        await task.value
        startTask = nil
    }

    private func begin(in context: ModelContext) async {
        lastError = nil
        collectedSegments = []
        accumulatedTranscript = ""
        sessionOffset = 0
        completedAudioSeconds = 0

        // Inserted up front so a crash mid-meeting still leaves a findable record,
        // but not published until recording actually starts — the window selects
        // whatever activeMeeting names, and a failed start deletes it out from under
        // the detail view.
        let meeting = Meeting()
        context.insert(meeting)
        context.saveOrLog()

        // Diarization is best-effort. Failing to load the models costs speaker labels,
        // not the meeting.
        do {
            try await diarizer.prepare()
            diarizationActive = true
        } catch {
            diarizationActive = false
            lastError = "Speaker separation unavailable: \(error.localizedDescription)"
            Log.meetings.error("Diarizer unavailable: \(error, privacy: .public)")
        }

        engine.collectTimedSegments = true

        // Keep the audio, if the user wants it kept. Started before capture so the
        // first buffer is not lost while the file is being opened.
        keepingAudio = settings.keepMeetingAudio
        if keepingAudio {
            meeting.audioFileName = audioWriter.begin()
        }

        installAudioTap()

        do {
            try await engine.startRecording(
                owner: .meeting,
                contextualStrings: settings.vocabularyHints,
                inputDeviceUID: meetingInputDeviceUID(),
                publishesSpectrum: settings.showMeetingIndicator
            )
        } catch {
            lastError = error.localizedDescription
            audioWriter.discard()
            await teardown()
            MeetingAudioStore.delete(fileNamed: meeting.audioFileName)
            context.delete(meeting)
            context.saveOrLog()
            activeMeeting = nil
            state = .idle
            AudioFeedbackService.shared.playIfEnabled(.error, settings: settings)
            return
        }

        sessionStartedAt = Date()
        activeMeeting = meeting
        state = .recording
        #if os(macOS)
        startIndicator()
        #endif
        AudioFeedbackService.shared.playIfEnabled(.recordingStarted, settings: settings)
        Log.meetings.notice("Meeting started, diarization: \(self.diarizationActive, privacy: .public)")
    }

    /// The device this meeting records from.
    ///
    /// With system audio on, that is a private aggregate carrying the microphone and
    /// system playback together. Falling back to the plain microphone on failure is
    /// deliberate: half a meeting beats none, and the reason is surfaced rather than
    /// swallowed.
    private func meetingInputDeviceUID() -> String {
        guard settings.captureSystemAudioInMeetings else {
            systemAudioActive = false
            return settings.inputDeviceUID
        }

        if systemAudio.isActive, let uid = systemAudio.aggregateUID {
            return uid
        }

        do {
            let micUID = settings.inputDeviceUID == AudioInputDevice.systemDefaultUID
                ? nil
                : settings.inputDeviceUID
            let uid = try systemAudio.start(microphoneUID: micUID)
            systemAudioActive = true
            return uid
        } catch {
            systemAudioActive = false
            lastError = error.localizedDescription
            Log.meetings.error("System audio unavailable, microphone only: \(error, privacy: .public)")
            return settings.inputDeviceUID
        }
    }

    /// When the session currently capturing began.
    ///
    /// The recorded length is the sum of these stretches. Measured from the last
    /// transcribed run instead, a meeting that ended in a minute of silence reported
    /// five seconds recorded and called itself paused.
    private var sessionStartedAt: Date?

    /// Whether this meeting is keeping its audio, decided when it started.
    ///
    /// Read once rather than per session: changed during a pause, the setting used to
    /// leave a five minute recording under a ten minute transcript, or switch on a
    /// writer that had never opened a file and record nothing at all.
    private var keepingAudio = false

    /// Route captured audio to the recording file and the diarizer.
    ///
    /// One tap, two consumers: diarization needs 16 kHz mono floats, the recording
    /// wants the buffer untouched. Opening the microphone twice to serve both would
    /// give two clocks and two timelines.
    private func installAudioTap() {
        let diarizer = self.diarizer
        let writer = audioWriter
        let wantsDiarization = diarizationActive
        let wantsAudio = keepingAudio
        let audioConverter = converter

        let (feed, continuation) = AsyncStream<[Float]>.makeStream()
        diarizerFeed = continuation
        diarizerFeedTask = Task.detached {
            for await samples in feed {
                await diarizer.append(samples)
            }
        }

        engine.audioTap = { buffer in
            if wantsAudio {
                writer.append(buffer)
            }
            if wantsDiarization, let audioConverter,
               let samples = audioConverter.floats(from: buffer) {
                continuation.yield(samples)
            }
        }
    }

    /// Wait for every buffer already captured to reach the diarizer.
    ///
    /// Anything that reads the diarizer's clock or asks it for turns has to run after
    /// the queued audio, or it measures a meeting shorter than the one recorded.
    private func drainDiarizerFeed() async {
        diarizerFeed?.finish()
        await diarizerFeedTask?.value
        diarizerFeed = nil
        diarizerFeedTask = nil
    }

    /// Stop capturing without ending the meeting.
    ///
    /// The engine is torn down rather than left idling, so the microphone indicator
    /// goes out and nothing is recorded while paused. The diarizer is deliberately
    /// left alive: it holds the speaker embeddings that let someone who talked before
    /// the pause keep their identity after it.
    func pause() async {
        guard state == .recording, transitionTask == nil else { return }

        let task = Task {
            await self.performPause()
            self.transitionTask = nil
        }
        transitionTask = task
        await task.value
    }

    private func performPause() async {
        // Disconnected before the stop is awaited, not after. The engine reads
        // `audioTap` once when a session starts, so clearing it here leaves this
        // session's own fan-out intact while making sure the next session — a
        // dictation taken during the pause — is not written into this meeting's
        // recording and fed to its diarizer, shifting every later timestamp.
        engine.audioTap = nil

        let transcript = (try? await engine.stopRecording(owner: .meeting)) ?? engine.currentTranscript
        harvestSession(transcript: transcript)

        // Turned off only once the session is harvested. The engine reads this flag on
        // every final result, and the stop's finalize step is exactly when the last
        // words before the pause become final; switched off before the stop, they
        // reached the plain transcript and never the speaker transcript.
        engine.collectTimedSegments = false

        await drainDiarizerFeed()

        state = .paused
        AudioFeedbackService.shared.playIfEnabled(.recordingStopped, settings: settings)
        Log.meetings.notice("Paused at \(Int(self.completedAudioSeconds), privacy: .public)s of audio")
    }

    /// Start capturing again, continuing the same meeting.
    func resume() async {
        guard state == .paused, transitionTask == nil else { return }

        let task = Task {
            await self.performResume()
            self.transitionTask = nil
        }
        transitionTask = task
        await task.value
    }

    private func performResume() async {
        // Anchor the new session to the diarizer's clock, which counts only audio it
        // has actually received — the same quantity the transcript timestamps measure.
        sessionOffset = diarizationActive ? await diarizer.receivedSeconds : completedAudioSeconds

        // Reconnected here, having been cleared on pause.
        engine.collectTimedSegments = true
        installAudioTap()

        do {
            try await engine.startRecording(
                owner: .meeting,
                contextualStrings: settings.vocabularyHints,
                inputDeviceUID: meetingInputDeviceUID()
            )
        } catch {
            // Put back the disconnection pause made. The meeting stays paused, and a
            // tap left attached would write the next dictation into this meeting's
            // recording and feed it to its diarizer.
            engine.audioTap = nil
            engine.collectTimedSegments = false
            await drainDiarizerFeed()

            lastError = error.localizedDescription
            AudioFeedbackService.shared.playIfEnabled(.error, settings: settings)
            Log.meetings.error("Could not resume: \(error, privacy: .public)")
            return
        }

        sessionStartedAt = Date()
        state = .recording
        AudioFeedbackService.shared.playIfEnabled(.recordingStarted, settings: settings)
        Log.meetings.notice("Resumed at offset \(Int(self.sessionOffset), privacy: .public)s")
    }

    /// Move this session's results onto the meeting clock.
    private func harvestSession(transcript: String) {
        let offset = sessionOffset

        collectedSegments.append(contentsOf: engine.timedSegments.map { segment in
            TimedTranscriptSegment(
                text: segment.text,
                start: segment.start + offset,
                end: segment.end + offset
            )
        })

        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            accumulatedTranscript += accumulatedTranscript.isEmpty ? trimmed : " " + trimmed
        }

        // Wall clock across the stretch that was actually capturing. Nothing is
        // recorded while paused, so this is both the length of the audio file and the
        // clock the segment offsets are placed on.
        if let sessionStartedAt {
            completedAudioSeconds += Date().timeIntervalSince(sessionStartedAt)
        }
        sessionStartedAt = nil

        // Written through on every harvest, not only at stop(). A crash or a kill that
        // never reaches stop() then costs the current session rather than the meeting.
        activeMeeting?.rawTranscript = accumulatedTranscript
        activeMeeting?.recordedDuration = completedAudioSeconds
    }

    /// End the meeting, align speakers to text, and save.
    func stop(in context: ModelContext) async {
        // Let a start in flight finish first. It ends by either adopting its meeting or
        // deleting it, so once it returns this is an ordinary stop of a recording
        // meeting, or there is nothing left to stop.
        if state == .preparing {
            await startTask?.value
        }

        // Likewise a pause or resume in flight. Each ends in a settled state, recording
        // or paused, and this stop then ends the meeting from there. Looped because
        // another click can begin a new step in the moment between one finishing and
        // this carrying on.
        while let transition = transitionTask {
            await transition.value
        }

        // Quitting calls this while the Stop button's save is still running. That
        // caller has to wait for the save in flight; turning it away here reports a
        // meeting written that is still halfway through being written.
        if state == .finishing {
            await finishTask?.value
            return
        }

        guard state == .recording || state == .paused, let meeting = activeMeeting else { return }

        let wasRecording = state == .recording
        state = .finishing

        let task = Task { await self.finish(meeting, wasRecording: wasRecording, in: context) }
        finishTask = task
        await task.value
        finishTask = nil
    }

    private func finish(_ meeting: Meeting, wasRecording: Bool, in context: ModelContext) async {
        if wasRecording {
            AudioFeedbackService.shared.playIfEnabled(.recordingStopped, settings: settings)

            // Disconnected before the stop is awaited, for the same reason as in
            // pause(): this session keeps its own fan-out, and anything started
            // afterwards must not be recorded into this meeting.
            engine.audioTap = nil

            let transcript = (try? await engine.stopRecording(owner: .meeting)) ?? engine.currentTranscript
            harvestSession(transcript: transcript)

            // After the harvest, as in pause(): the stop is what makes the last words
            // final, and they are only collected while this is on.
            engine.collectTimedSegments = false
        }

        await drainDiarizerFeed()
        let turns = diarizationActive ? await diarizer.finish() : []

        meeting.endedAt = Date()
        meeting.recordedDuration = completedAudioSeconds
        meeting.audioFileName = audioWriter.finish()
        meeting.rawTranscript = TextProcessor.process(
            accumulatedTranscript,
            replacements: settings.wordReplacements
        )

        applyAttribution(timedSegments: collectedSegments, turns: turns, to: meeting, in: context)

        context.saveOrLog()
        await teardown()

        state = .idle
        #if os(macOS)
        stopIndicator()
        #endif
        activeMeeting = nil
        AudioFeedbackService.shared.playIfEnabled(.processingComplete, settings: settings)

        // The title is the user's own words, so it is left private and the system
        // redacts it. The counts are what make the line worth keeping.
        Log.meetings.notice("""
            saved "\(meeting.title)" — \
            \(meeting.utterances.count, privacy: .public) utterances, \
            \(meeting.speakers.count, privacy: .public) speakers
            """)
    }

    // MARK: - Attribution

    /// Turn timed transcript runs plus speaker turns into stored utterances.
    private func applyAttribution(
        timedSegments: [TimedTranscriptSegment],
        turns: [SpeakerTurn],
        to meeting: Meeting,
        in context: ModelContext
    ) {
        // Without timings there is nothing to align against; the raw transcript on the
        // meeting is the whole result.
        guard !timedSegments.isEmpty else {
            Log.meetings.notice("No timed segments — transcript kept without attribution")
            return
        }

        let aligned = SpeakerAlignment.align(transcript: timedSegments, turns: turns)
        let labels = SpeakerAlignment.generatedLabels(for: aligned)

        for (speakerId, label) in labels {
            let speaker = MeetingSpeaker(speakerId: speakerId, generatedLabel: label)
            speaker.meeting = meeting
            context.insert(speaker)
        }

        // The same pass `rawTranscript` gets. Every reader prefers the utterances once
        // there is attribution, so without this the meeting displays and exports the
        // words "period" and "comma" while the raw transcript has the marks.
        for item in aligned {
            let utterance = Utterance(
                speakerId: item.speakerId,
                text: TextProcessor.process(
                    item.text,
                    replacements: settings.wordReplacements
                ),
                start: item.start,
                end: item.end
            )
            utterance.meeting = meeting
            context.insert(utterance)
        }
    }

    // MARK: - Summary

    /// Generate an AI summary for a finished meeting.
    func summarize(_ meeting: Meeting, in context: ModelContext) async throws {
        let body = MeetingExporter.plainText(meeting)
        guard !body.isEmpty else { return }

        let summary = try await aiProcessor.process(text: body, promptId: settings.selectedPromptId)

        // The summary takes long enough that the meeting can be deleted while it runs.
        guard !meeting.isDeleted else { return }

        meeting.summary = summary
        context.saveOrLog()
    }

    // MARK: - Teardown

    private func teardown() async {
        engine.audioTap = nil
        engine.collectTimedSegments = false
        await drainDiarizerFeed()
        await diarizer.reset()
        diarizationActive = false

        // The tap and its aggregate outlive the app if not destroyed, so this runs on
        // every exit path rather than only the successful one.
        systemAudio.stop()
        systemAudioActive = false
    }
}
