import AVFoundation
import Combine
import Foundation
import Speech
import Observation
import CoreMedia
import os

/// Unified transcription engine for background voice-to-text
/// Uses Apple's modern SpeechAnalyzer API (iOS 26+/macOS 26+)
@MainActor
@Observable
final class TranscriptionEngine {

    // MARK: - Published State

    /// How far along the one session this engine runs is.
    ///
    /// A plain `isRecording` flag could only be true once everything was built and
    /// false the moment teardown began, which left the engine looking free for the
    /// few hundred milliseconds either side. Every guard that asked got the wrong
    /// answer there: a released hotkey did not stop a session that was still coming
    /// up, and a second dictation walked into the middle of the first one's finish
    /// and took its transcript with it.
    enum SessionPhase: Sendable, Equatable {
        /// Nobody holds the engine.
        case idle
        /// Claimed and being built, or reserved by a caller that is not ready yet.
        case starting
        /// Live and transcribing.
        case recording
        /// Finalizing. The claim is still held, so nothing else may start.
        case stopping
    }

    private(set) var phase: SessionPhase = .idle

    /// Whether audio is being transcribed right now.
    var isRecording: Bool { phase == .recording }

    /// Whether anyone holds the engine, at any stage. This is the claim guard.
    var isBusy: Bool { phase != .idle }

    /// Who a running session belongs to.
    ///
    /// One engine serves both dictation and meetings, so `isRecording` alone cannot
    /// say whose session it is. Without this, a hotkey press during a meeting tears
    /// down the meeting's session while the meeting UI carries on as if recording.
    private(set) var owner: SessionOwner?

    private(set) var currentTranscript = ""
    private(set) var volatileText = ""  // Live, unconfirmed text
    private(set) var error: TranscriptionEngineError?

    /// Finalized transcript runs with the audio time range each covers.
    ///
    /// Meeting mode aligns these against diarizer segments to decide who said what.
    /// Populated only while `collectTimedSegments` is on, since plain dictation has no
    /// use for them.
    private(set) var timedSegments: [TimedTranscriptSegment] = []

    /// Collect `timedSegments` during this recording.
    var collectTimedSegments = false

    /// A second consumer for the raw microphone buffers, such as diarization.
    ///
    /// Fanned out from the one capture rather than opening the microphone twice —
    /// two AVAudioEngines on one device fight over the format.
    var audioTap: (@Sendable (AVAudioPCMBuffer) -> Void)?

    /// The two callers that drive this engine.
    enum SessionOwner: String, Sendable {
        case dictation
        case meeting
    }

    // MARK: - Audio Components

    private var audioCaptureHelper: AudioCaptureHelper?
    private var audioProcessingTask: Task<Void, Never>?

    // MARK: - Speech Components

    private var speechTranscriber: SpeechTranscriber?
    private var speechAnalyzer: SpeechAnalyzer?
    private var analyzerInputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var recognitionTask: Task<Void, any Error>?

    private let bufferConverter = BufferConverter()
    private var analyzerFormat: AVAudioFormat?

    // MARK: - Latency Measurement

    /// Written to the unified log, so a dictation that goes wrong in a launched app
    /// still leaves evidence. `print` reaches nobody outside Xcode.
    nonisolated static let log = Logger(subsystem: "com.inscribe.app", category: "Dictation")

    /// When audio started flowing, which is time zero for every latency number below.
    private var sessionStart: ContinuousClock.Instant?

    /// Reports how long the main actor goes unattended while a session runs.
    private var heartbeatTask: Task<Void, Never>?

    /// Seconds since `start`, on a clock no wall-clock adjustment can move.
    nonisolated static func seconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
    }

    /// Log every stretch the main actor spends unable to answer.
    ///
    /// Results are consumed on the main actor, so anything that holds it up holds up
    /// the words. This says whether that is happening and for how long.
    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { @MainActor in
            var last = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                let now = ContinuousClock.now
                let gap = Self.seconds(since: last)
                last = now
                if gap > 0.15 {
                    Self.log.notice("main actor stalled \(gap, format: .fixed(precision: 3), privacy: .public)s")
                }
            }
        }
    }

    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    // MARK: - Configuration

    static let defaultLocale = Locale(
        components: .init(languageCode: .english, script: nil, languageRegion: .unitedStates)
    )

    private static let fallbackLocales = [
        Locale(components: .init(languageCode: .english, script: nil, languageRegion: .unitedStates)),
        Locale(components: .init(languageCode: .english, script: nil, languageRegion: .unitedKingdom)),
        Locale(identifier: "en-US"),
        Locale(identifier: "en"),
        Locale.current
    ]

    // MARK: - Initialization

    /// The one engine in the process.
    ///
    /// App Intents are built by the system and cannot be handed the app's own
    /// dependencies, so an intent that made its own engine opened a second microphone
    /// session the `isRecording` guard could not see. Everything that records goes
    /// through this instance, which is what makes that guard mean anything.
    static let shared = TranscriptionEngine()

    init() {}

    // MARK: - Public API

    /// Claim the engine before the caller is ready to record.
    ///
    /// Meeting mode loads its diarization models first, which takes seconds on a cold
    /// start. Without a claim the engine looks free for that whole stretch, and a
    /// dictation taken in the middle of it wins the race and leaves the meeting
    /// deleted before it began.
    ///
    /// Returns false when someone else already holds the engine.
    func reserve(owner: SessionOwner) -> Bool {
        guard phase == .idle else { return false }
        self.owner = owner
        phase = .starting
        return true
    }

    /// Give back a claim that never became a recording.
    func releaseReservation(owner: SessionOwner) {
        guard phase == .starting, self.owner == owner else { return }
        self.owner = nil
        phase = .idle
    }

    /// Start recording and transcribing audio
    /// - Parameters:
    ///   - contextualStrings: Terms to bias the recognizer toward — names, jargon.
    ///   - inputDeviceUID: CoreAudio UID of the microphone, or "default".
    func startRecording(
        owner: SessionOwner = .dictation,
        contextualStrings: [String] = [],
        inputDeviceUID: String = "default"
    ) async throws {
        // Thrown rather than returned: a caller that silently "succeeds" here goes on to
        // set up its own UI for a session that does not exist, and only finds out when
        // the recording turns out to be empty.
        //
        // Already `.starting` under this owner is the one exception: that is a caller
        // that reserved the engine and has now finished getting ready.
        let heldByThisCaller = (phase == .starting && self.owner == owner)
        if !heldByThisCaller {
            guard phase == .idle else {
                throw TranscriptionEngineError.busy(owner: self.owner?.rawValue ?? "another session")
            }
            self.owner = owner
            phase = .starting
        }

        print("[TranscriptionEngine] Starting recording...")

        // A previous start that threw part-way leaves an analyzer and a capture
        // helper alive with isRecording still false, which no stop path will ever
        // reach — both guard on isRecording. Clear that before building anything.
        teardownSession()

        error = nil
        currentTranscript = ""
        volatileText = ""
        timedSegments = []

        // Check authorization
        guard await checkAuthorization() else {
            release()
            throw TranscriptionEngineError.notAuthorized
        }

        // Setup speech recognition first
        do {
            try await setupSpeechRecognition(contextualStrings: contextualStrings)
        } catch {
            // Never leave a started analyzer behind. Releasing one while its input
            // task is still reading traps inside SpeechAnalyzer.analyzeSequence.
            teardownSession()
            release()
            throw error
        }

        // Start audio capture using non-MainActor helper
        let helper = AudioCaptureHelper()
        let audioStream: AsyncStream<AudioData>
        do {
            audioStream = try helper.startCapture(preferredDeviceUID: inputDeviceUID)
        } catch {
            helper.stopCapture()
            teardownSession()
            release()
            throw error
        }

        // Assigned only once capture is live: a helper stored before it succeeds
        // would be released by the next start, and its deinit blocks in
        // AVAudioEngine.stop() on whichever thread does the releasing.
        self.audioCaptureHelper = helper

        // Time zero for every latency number, set before any audio can be read.
        let sessionStart = ContinuousClock.now
        self.sessionStart = sessionStart

        // Start processing task to convert and feed audio to analyzer
        let analyzerContinuation = analyzerInputContinuation
        let targetFormat = analyzerFormat!

        let tap = audioTap

        audioProcessingTask = Task.detached {
            Self.log.notice("audio task started")

            let converter = BufferConverter()
            var bufferCount = 0
            var successCount = 0
            var failureCount = 0
            var audioSeconds = 0.0

            for await audioData in audioStream {
                bufferCount += 1
                audioSeconds += Double(audioData.buffer.frameLength)
                    / audioData.buffer.format.sampleRate

                // Hand the untouched buffer to any second consumer before conversion,
                // so diarization sees the same audio the transcriber does.
                tap?(audioData.buffer)

                do {
                    let converted = try converter.convertBuffer(audioData.buffer, to: targetFormat)
                    let input = AnalyzerInput(buffer: converted)
                    analyzerContinuation?.yield(input)
                    successCount += 1
                } catch {
                    failureCount += 1
                    Self.log.error("conversion failed on buffer #\(bufferCount, privacy: .public): \(error, privacy: .public)")
                }

                // Every hundred buffers, say whether audio is reaching the analyzer as
                // fast as it is spoken. Drift above zero means the feed itself is late.
                if bufferCount % 100 == 0 {
                    let elapsed = Self.seconds(since: sessionStart)
                    Self.log.notice("audio fed=\(audioSeconds, format: .fixed(precision: 2), privacy: .public)s elapsed=\(elapsed, format: .fixed(precision: 2), privacy: .public)s drift=\(elapsed - audioSeconds, format: .fixed(precision: 2), privacy: .public)s buffers=\(bufferCount, privacy: .public)")
                }
            }
            Self.log.notice("audio task ended buffers=\(bufferCount, privacy: .public) converted=\(successCount, privacy: .public) failed=\(failureCount, privacy: .public) audio=\(audioSeconds, format: .fixed(precision: 2), privacy: .public)s elapsed=\(Self.seconds(since: sessionStart), format: .fixed(precision: 2), privacy: .public)s")
        }

        phase = .recording
        startHeartbeat()
        Self.log.notice("recording started for \(owner.rawValue, privacy: .public)")
    }

    /// Stop recording and return the final transcript
    @discardableResult
    func stopRecording(owner: SessionOwner = .dictation) async throws -> String {
        guard phase == .recording else {
            print("[TranscriptionEngine] Not recording, ignoring stop request")
            return currentTranscript
        }

        // Refuse to end someone else's session: a dictation hotkey must not stop a
        // meeting that happens to be using the same engine.
        guard self.owner == owner else {
            print("[TranscriptionEngine] \(owner.rawValue) tried to stop a \(self.owner?.rawValue ?? "?") session")
            return currentTranscript
        }

        let sessionStart = self.sessionStart ?? .now
        Self.log.notice("stop requested at \(Self.seconds(since: sessionStart), format: .fixed(precision: 2), privacy: .public)s, transcript=\(self.currentTranscript.count, privacy: .public) chars, volatile=\(self.volatileText.count, privacy: .public) chars")

        // Held, not released: nothing else may take the engine until this session has
        // finished handing back its words.
        phase = .stopping
        stopHeartbeat()

        // Stop audio capture helper. This finishes the audio stream, so the task
        // below runs out of buffers on its own.
        audioCaptureHelper?.stopCapture()
        audioCaptureHelper = nil

        // Awaited rather than cancelled. An AsyncStream iterator throws away whatever
        // is still buffered when it is cancelled, and what is still buffered is
        // always the end of the sentence the user just spoke.
        await audioProcessingTask?.value
        audioProcessingTask = nil
        Self.log.notice("audio drained at \(Self.seconds(since: sessionStart), format: .fixed(precision: 2), privacy: .public)s, transcript=\(self.currentTranscript.count, privacy: .public) chars")

        // Finalize transcription
        analyzerInputContinuation?.finish()

        do {
            try await speechAnalyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            Self.log.error("finalize failed: \(error, privacy: .public)")
            self.error = .transcriptionFailed(error.localizedDescription)
        }
        Self.log.notice("finalize returned at \(Self.seconds(since: sessionStart), format: .fixed(precision: 2), privacy: .public)s, transcript=\(self.currentTranscript.count, privacy: .public) chars, volatile=\(self.volatileText.count, privacy: .public) chars")

        // Cancel recognition task and give it time to clean up
        recognitionTask?.cancel()
        try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms for cleanup
        Self.log.notice("after cancel+100ms at \(Self.seconds(since: sessionStart), format: .fixed(precision: 2), privacy: .public)s, transcript=\(self.currentTranscript.count, privacy: .public) chars, volatile=\(self.volatileText.count, privacy: .public) chars")

        recognitionTask = nil
        teardownSession()

        // Append any remaining volatile text
        if !volatileText.isEmpty {
            currentTranscript += volatileText
            volatileText = ""
        }

        release()

        Self.log.notice("recording stopped, delivering \(self.currentTranscript.count, privacy: .public) chars")
        return currentTranscript
    }

    /// Hand the engine back.
    private func release() {
        self.owner = nil
        phase = .idle
    }

    /// Cancel recording without returning transcript
    func cancelRecording(owner: SessionOwner = .dictation) {
        guard phase == .starting || phase == .recording else { return }

        guard self.owner == owner else {
            print("[TranscriptionEngine] \(owner.rawValue) tried to cancel a \(self.owner?.rawValue ?? "?") session")
            return
        }

        Self.log.notice("recording cancelled")
        stopHeartbeat()
        release()

        audioCaptureHelper?.stopCapture()
        audioCaptureHelper = nil
        audioProcessingTask?.cancel()
        audioProcessingTask = nil
        analyzerInputContinuation?.finish()
        teardownSession()

        currentTranscript = ""
        volatileText = ""
    }

    // MARK: - Authorization

    private func checkAuthorization() async -> Bool {
        // Check microphone access
        let micAuthorized = await checkMicrophoneAuthorization()
        guard micAuthorized else { return false }

        // Check speech recognition access
        let speechAuthorized = await checkSpeechRecognitionAuthorization()
        return speechAuthorized
    }

    private func checkMicrophoneAuthorization() async -> Bool {
        let audioStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        print("[TranscriptionEngine] Microphone auth status: \(audioStatus.rawValue) (0=notDetermined, 1=restricted, 2=denied, 3=authorized)")

        switch audioStatus {
        case .authorized:
            print("[TranscriptionEngine] Microphone already authorized")
            return true
        case .notDetermined:
            print("[TranscriptionEngine] Requesting microphone access...")
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            print("[TranscriptionEngine] Microphone access granted: \(granted)")
            if !granted {
                error = .notAuthorized
            }
            return granted
        case .denied, .restricted:
            print("[TranscriptionEngine] Microphone access denied or restricted")
            error = .notAuthorized
            return false
        @unknown default:
            error = .notAuthorized
            return false
        }
    }

    private func checkSpeechRecognitionAuthorization() async -> Bool {
        let status = SFSpeechRecognizer.authorizationStatus()

        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        case .denied, .restricted:
            error = .notAuthorized
            return false
        @unknown default:
            error = .notAuthorized
            return false
        }
    }

    /// Request authorization proactively (call on app launch)
    func requestAuthorization() async -> Bool {
        await checkAuthorization()
    }

    // MARK: - Speech Recognition Setup

    private func setupSpeechRecognition(contextualStrings: [String] = []) async throws {
        print("[TranscriptionEngine] Setting up speech recognition...")

        // Resolved before the transcriber is built, not after: a transcriber is bound to
        // the locale it is created with, so choosing one afterwards changes nothing.
        let locale = try await resolveSupportedLocale()

        // Create input stream for analyzer
        let (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.analyzerInputContinuation = inputContinuation

        // Create transcriber
        speechTranscriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )

        guard let transcriber = speechTranscriber else {
            throw TranscriptionEngineError.setupFailed("Failed to create SpeechTranscriber")
        }

        // Create analyzer with transcriber
        speechAnalyzer = SpeechAnalyzer(modules: [transcriber])

        // Bias the recognizer toward the user's own vocabulary. Unlike a post-hoc
        // replacement this changes what the model is listening for, which is what
        // proper nouns need.
        let hints = contextualStrings.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if !hints.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = hints
            do {
                try await speechAnalyzer?.setContext(context)
                print("[TranscriptionEngine] Applied \(hints.count) vocabulary hints")
            } catch {
                // Worth continuing without: hints improve accuracy, they are not required.
                print("[TranscriptionEngine] Could not apply vocabulary hints: \(error)")
            }
        }

        // Ensure model is available
        try await ensureModelAvailable(transcriber: transcriber, locale: locale)

        // Get best audio format
        analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])

        guard analyzerFormat != nil else {
            throw TranscriptionEngineError.setupFailed("No compatible audio format")
        }

        // Start recognition task to process results
        recognitionTask = Task { [weak self] in
            Self.log.notice("recognition task started")
            var resultCount = 0
            var lastLoggedVolatile = 0.0
            var endedByCancel = false
            do {
                for try await result in transcriber.results {
                    // Check for cancellation
                    guard !Task.isCancelled else {
                        // The one line that says whether stopping threw words away: a
                        // stream that ended on its own never reaches this.
                        endedByCancel = true
                        Self.log.error("recognition task CANCELLED after \(resultCount, privacy: .public) results — anything still queued was dropped")
                        break
                    }

                    let text = String(result.text.characters)
                    resultCount += 1

                    // How far behind the speech this result arrived. `audioEnd` is the
                    // moment in the recording the words cover; `elapsed` is the clock.
                    let audioEnd = result.range.end.seconds
                    let elapsed = self?.sessionStart.map { Self.seconds(since: $0) } ?? 0
                    let shouldLog = result.isFinal || elapsed - lastLoggedVolatile > 0.5
                    if shouldLog {
                        if !result.isFinal { lastLoggedVolatile = elapsed }
                        Self.log.notice("result #\(resultCount, privacy: .public) final=\(result.isFinal, privacy: .public) audioEnd=\(audioEnd, format: .fixed(precision: 2), privacy: .public)s elapsed=\(elapsed, format: .fixed(precision: 2), privacy: .public)s lag=\(elapsed - audioEnd, format: .fixed(precision: 2), privacy: .public)s chars=\(text.count, privacy: .public)")
                    }

                    // Update state on MainActor
                    // Read the run attributes off the actor, then hand over plain values.
                    let runs: [TimedTranscriptSegment] = result.isFinal
                        ? Self.timedRuns(from: result.text)
                        : []

                    await MainActor.run {
                        guard let self = self else { return }
                        if result.isFinal {
                            self.currentTranscript += text
                            self.volatileText = ""
                            if self.collectTimedSegments {
                                self.timedSegments.append(contentsOf: runs)
                            }
                        } else {
                            self.volatileText = text
                        }
                    }
                }
                if !endedByCancel {
                    Self.log.notice("recognition stream ended on its own after \(resultCount, privacy: .public) results")
                }
            } catch {
                Self.log.error("recognition failed after \(resultCount, privacy: .public) results: \(error, privacy: .public)")
                await MainActor.run {
                    self?.error = .transcriptionFailed(error.localizedDescription)
                }
            }
        }

        // Start analyzer
        try await speechAnalyzer?.start(inputSequence: inputStream)
        print("[TranscriptionEngine] Speech recognition setup complete")
    }

    /// Split a finalized result into runs carrying an audio time range.
    ///
    /// `attributeOptions: [.audioTimeRange]` makes the transcriber stamp each run with
    /// when it was spoken. That timestamp is what lets speaker attribution be real
    /// rather than a proportional guess at how the text divides up.
    private nonisolated static func timedRuns(from text: AttributedString) -> [TimedTranscriptSegment] {
        var segments: [TimedTranscriptSegment] = []

        for run in text.runs {
            guard let range = run.audioTimeRange else { continue }
            let piece = String(text[run.range].characters)
            guard !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            segments.append(TimedTranscriptSegment(
                text: piece,
                start: range.start.seconds,
                end: range.end.seconds
            ))
        }

        return segments
    }

    /// The first locale in `fallbackLocales` this system can actually transcribe.
    private func resolveSupportedLocale() async throws -> Locale {
        let supported = await SpeechTranscriber.supportedLocales

        for candidate in Self.fallbackLocales
        where supported.contains(where: { $0.identifier(.bcp47) == candidate.identifier(.bcp47) }) {
            return candidate
        }

        throw TranscriptionEngineError.localeNotSupported
    }

    private func ensureModelAvailable(transcriber: SpeechTranscriber, locale: Locale) async throws {
        print("[TranscriptionEngine] Ensuring model is available...")

        // Check if download is needed
        if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            print("[TranscriptionEngine] Downloading speech model...")
            try await downloader.downloadAndInstall()
        }

        // Reserve the locale
        let reservedLocales = await AssetInventory.reservedLocales
        if !reservedLocales.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
            try await AssetInventory.reserve(locale: locale)
        }

        print("[TranscriptionEngine] Using locale: \(locale.identifier)")
    }

    // MARK: - Cleanup

    /// Release everything a recording session owns, whether or not one is running.
    ///
    /// Safe to call at any point, including on a session that was never finished.
    /// Order matters: the input stream is finished and the recognition task cancelled
    /// *before* the analyzer is released. Dropping an analyzer whose input task is
    /// still reading traps inside `SpeechAnalyzer.analyzeSequence`.
    private func teardownSession() {
        // Stopped explicitly rather than left to deinit: AVAudioEngine.stop() blocks,
        // and deinit runs on whichever thread happens to drop the last reference.
        audioCaptureHelper?.stopCapture()
        audioCaptureHelper = nil

        audioProcessingTask?.cancel()
        audioProcessingTask = nil

        analyzerInputContinuation?.finish()
        analyzerInputContinuation = nil

        recognitionTask?.cancel()
        recognitionTask = nil

        speechTranscriber = nil
        speechAnalyzer = nil
        analyzerFormat = nil
    }

    deinit {
        MainActor.assumeIsolated {
            print("[TranscriptionEngine] Deallocating...")
            recognitionTask?.cancel()
            audioProcessingTask?.cancel()
            audioCaptureHelper?.stopCapture()
            // Inline cleanup
            audioCaptureHelper = nil
            audioProcessingTask = nil
            speechTranscriber = nil
            speechAnalyzer = nil
            analyzerInputContinuation = nil
            analyzerFormat = nil
        }
    }
}

// MARK: - Errors

enum TranscriptionEngineError: Error, LocalizedError {
    case notAuthorized
    case setupFailed(String)
    case transcriptionFailed(String)
    case localeNotSupported
    case busy(owner: String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Microphone access not authorized"
        case .setupFailed(let reason):
            return "Setup failed: \(reason)"
        case .transcriptionFailed(let reason):
            return "Transcription failed: \(reason)"
        case .localeNotSupported:
            return "No supported language locale found"
        case .busy(let owner):
            return "Already recording for \(owner)"
        }
    }
}
