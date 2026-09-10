import Foundation
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

    /// The save started by `stop()`, while it is still running.
    ///
    /// Quitting can call `stop()` a second time while the first one is mid-save. That
    /// caller waits on this rather than being turned away by the guard, which would
    /// report the meeting written and let the app terminate through the middle of it.
    private var finishTask: Task<Void, Never>?

    /// Ordered handoff of captured audio to the diarizer.
    ///
    /// The tap runs on the audio thread and the diarizer is an actor, so the handoff
    /// has to be asynchronous. A task per buffer arrives in whatever order the tasks
    /// were scheduled, which scrambles the 16 kHz stream the clustering reads.
    private var diarizerFeed: AsyncStream<[Float]>.Continuation?
    private var diarizerFeedTask: Task<Void, Never>?

    /// Live text: everything kept so far, plus whatever this session has heard.
    var liveTranscript: String {
        let current = engine.currentTranscript + engine.volatileText
        guard !accumulatedTranscript.isEmpty else { return current }
        guard !current.isEmpty else { return accumulatedTranscript }
        return accumulatedTranscript + " " + current
    }

    var isRecording: Bool { state == .recording }
    var isPaused: Bool { state == .paused }

    /// Whether a meeting is open, recording or not.
    var hasActiveMeeting: Bool { activeMeeting != nil && state != .idle }

    // MARK: - Initialization

    init(engine: TranscriptionEngine, settings: AppSettings, aiProcessor: AIProcessor) {
        self.engine = engine
        self.settings = settings
        self.aiProcessor = aiProcessor
    }

    // MARK: - Recording

    /// Begin a meeting, creating and inserting the record up front.
    ///
    /// The `Meeting` exists in the store from the first second, so a crash mid-meeting
    /// leaves a titled, findable record rather than nothing.
    func start(in context: ModelContext) async {
        guard state == .idle, !engine.isRecording else { return }

        state = .preparing
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
        try? context.save()

        // Diarization is best-effort. Failing to load the models costs speaker labels,
        // not the meeting.
        do {
            try await diarizer.prepare()
            diarizationActive = true
        } catch {
            diarizationActive = false
            lastError = "Speaker separation unavailable: \(error.localizedDescription)"
            print("[MeetingRecorder] Diarizer unavailable: \(error)")
        }

        engine.collectTimedSegments = true

        // Keep the audio, if the user wants it kept. Started before capture so the
        // first buffer is not lost while the file is being opened.
        if settings.keepMeetingAudio {
            meeting.audioFileName = audioWriter.begin()
        }

        installAudioTap()

        do {
            try await engine.startRecording(
                owner: .meeting,
                contextualStrings: settings.vocabularyHints,
                inputDeviceUID: meetingInputDeviceUID()
            )
        } catch {
            lastError = error.localizedDescription
            audioWriter.discard()
            await teardown()
            MeetingAudioStore.delete(fileNamed: meeting.audioFileName)
            context.delete(meeting)
            try? context.save()
            activeMeeting = nil
            state = .idle
            AudioFeedbackService.shared.playIfEnabled(.error, settings: settings)
            return
        }

        activeMeeting = meeting
        state = .recording
        AudioFeedbackService.shared.playIfEnabled(.recordingStarted, settings: settings)
        print("[MeetingRecorder] Meeting started, diarization: \(diarizationActive)")
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
            print("[MeetingRecorder] System audio unavailable, microphone only: \(error)")
            return settings.inputDeviceUID
        }
    }

    /// Route captured audio to the recording file and the diarizer.
    ///
    /// One tap, two consumers: diarization needs 16 kHz mono floats, the recording
    /// wants the buffer untouched. Opening the microphone twice to serve both would
    /// give two clocks and two timelines.
    private func installAudioTap() {
        let diarizer = self.diarizer
        let writer = audioWriter
        let wantsDiarization = diarizationActive
        let wantsAudio = settings.keepMeetingAudio
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
        guard state == .recording else { return }

        let transcript = (try? await engine.stopRecording(owner: .meeting)) ?? engine.currentTranscript
        harvestSession(transcript: transcript)

        // Disconnected while paused: the engine re-reads audioTap on every start, so a
        // dictation taken during the pause would otherwise be written into the meeting's
        // recording and fed to its diarizer, shifting every later timestamp.
        engine.audioTap = nil
        engine.collectTimedSegments = false
        await drainDiarizerFeed()

        state = .paused
        AudioFeedbackService.shared.playIfEnabled(.recordingStopped, settings: settings)
        print("[MeetingRecorder] Paused at \(Int(completedAudioSeconds))s of audio")
    }

    /// Start capturing again, continuing the same meeting.
    func resume() async {
        guard state == .paused else { return }

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
            print("[MeetingRecorder] Could not resume: \(error)")
            return
        }

        state = .recording
        AudioFeedbackService.shared.playIfEnabled(.recordingStarted, settings: settings)
        print("[MeetingRecorder] Resumed at offset \(Int(sessionOffset))s")
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

        // The last run's end is the best available measure of this session's audio,
        // and it is the same clock the offsets use.
        completedAudioSeconds = max(completedAudioSeconds, collectedSegments.last?.end ?? offset)

        // Written through on every harvest, not only at stop(). A crash or a kill that
        // never reaches stop() then costs the current session rather than the meeting.
        activeMeeting?.rawTranscript = accumulatedTranscript
        activeMeeting?.recordedDuration = completedAudioSeconds
    }

    /// End the meeting, align speakers to text, and save.
    func stop(in context: ModelContext) async {
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
            let transcript = (try? await engine.stopRecording(owner: .meeting)) ?? engine.currentTranscript
            harvestSession(transcript: transcript)
        }

        await drainDiarizerFeed()
        let turns = diarizationActive ? await diarizer.finish() : []

        meeting.endedAt = Date()
        meeting.recordedDuration = completedAudioSeconds
        meeting.audioFileName = audioWriter.finish()
        meeting.rawTranscript = TextProcessor.process(
            accumulatedTranscript,
            spokenPunctuation: settings.spokenPunctuationEnabled,
            replacements: settings.wordReplacements
        )

        applyAttribution(timedSegments: collectedSegments, turns: turns, to: meeting, in: context)

        try? context.save()
        await teardown()

        state = .idle
        activeMeeting = nil
        AudioFeedbackService.shared.playIfEnabled(.processingComplete, settings: settings)

        print("""
            [MeetingRecorder] Saved "\(meeting.title)" — \
            \(meeting.utterances.count) utterances, \(meeting.speakers.count) speakers
            """)
    }

    /// Abandon the meeting without keeping it.
    func cancel(in context: ModelContext) async {
        guard state != .idle else { return }

        engine.cancelRecording(owner: .meeting)
        audioWriter.discard()
        await teardown()

        if let meeting = activeMeeting {
            MeetingAudioStore.delete(fileNamed: meeting.audioFileName)
            context.delete(meeting)
            try? context.save()
        }

        activeMeeting = nil
        state = .idle
        AudioFeedbackService.shared.playIfEnabled(.recordingStopped, settings: settings)
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
            print("[MeetingRecorder] No timed segments — transcript kept without attribution")
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
                    spokenPunctuation: settings.spokenPunctuationEnabled,
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
        try? context.save()
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
