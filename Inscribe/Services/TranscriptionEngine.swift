import AVFoundation
import Combine
import Foundation
import Speech
import Observation
import CoreMedia

/// Unified transcription engine for background voice-to-text
/// Uses Apple's modern SpeechAnalyzer API (iOS 26+/macOS 26+)
@MainActor
@Observable
final class TranscriptionEngine {

    // MARK: - Published State

    private(set) var isRecording = false

    /// Who a running session belongs to.
    ///
    /// One engine serves both dictation and meetings, so `isRecording` alone cannot
    /// say whose session it is. Without this, a hotkey press during a meeting tears
    /// down the meeting's session while the meeting UI carries on as if recording.
    private(set) var owner: SessionOwner?

    /// Identifies the current session across suspension points.
    ///
    /// `stopRecording` awaits several times. A new session started during one of those
    /// awaits would otherwise be torn down by the older call finishing its work.
    private var sessionID = UUID()
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
        guard !isRecording else {
            throw TranscriptionEngineError.busy(owner: self.owner?.rawValue ?? "another session")
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
            throw TranscriptionEngineError.notAuthorized
        }

        // Setup speech recognition first
        do {
            try await setupSpeechRecognition(contextualStrings: contextualStrings)
        } catch {
            // Never leave a started analyzer behind. Releasing one while its input
            // task is still reading traps inside SpeechAnalyzer.analyzeSequence.
            teardownSession()
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
            throw error
        }

        // Assigned only once capture is live: a helper stored before it succeeds
        // would be released by the next start, and its deinit blocks in
        // AVAudioEngine.stop() on whichever thread does the releasing.
        self.audioCaptureHelper = helper

        // Start processing task to convert and feed audio to analyzer
        let analyzerContinuation = analyzerInputContinuation
        let targetFormat = analyzerFormat!

        let tap = audioTap

        audioProcessingTask = Task.detached {
            print("[TranscriptionEngine] Audio processing task started")

            let converter = BufferConverter()
            var bufferCount = 0
            var successCount = 0

            for await audioData in audioStream {
                bufferCount += 1
                if bufferCount <= 5 || bufferCount % 100 == 0 {
                    print("[TranscriptionEngine] Processing buffer #\(bufferCount)")
                }

                // Hand the untouched buffer to any second consumer before conversion,
                // so diarization sees the same audio the transcriber does.
                tap?(audioData.buffer)

                do {
                    let converted = try converter.convertBuffer(audioData.buffer, to: targetFormat)
                    let input = AnalyzerInput(buffer: converted)
                    analyzerContinuation?.yield(input)
                    successCount += 1
                } catch {
                    if bufferCount <= 3 {
                        print("[TranscriptionEngine] Conversion error: \(error)")
                    }
                }
            }
            print("[TranscriptionEngine] Processing ended - total: \(bufferCount), success: \(successCount)")
        }

        self.owner = owner
        sessionID = UUID()
        isRecording = true
        print("[TranscriptionEngine] Recording started for \(owner.rawValue)")
    }

    /// Stop recording and return the final transcript
    @discardableResult
    func stopRecording(owner: SessionOwner = .dictation) async throws -> String {
        guard isRecording else {
            print("[TranscriptionEngine] Not recording, ignoring stop request")
            return currentTranscript
        }

        // Refuse to end someone else's session: a dictation hotkey must not stop a
        // meeting that happens to be using the same engine.
        guard self.owner == owner else {
            print("[TranscriptionEngine] \(owner.rawValue) tried to stop a \(self.owner?.rawValue ?? "?") session")
            return currentTranscript
        }

        print("[TranscriptionEngine] Stopping recording...")
        let stoppingSession = sessionID
        isRecording = false
        self.owner = nil

        // Stop audio capture helper
        audioCaptureHelper?.stopCapture()
        audioCaptureHelper = nil

        // Cancel audio processing task
        audioProcessingTask?.cancel()
        audioProcessingTask = nil

        // Finalize transcription
        analyzerInputContinuation?.finish()

        do {
            try await speechAnalyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            print("[TranscriptionEngine] Error finalizing transcription: \(error)")
            self.error = .transcriptionFailed(error.localizedDescription)
        }

        // Checked before anything is cancelled, not after. A session started while the
        // finalize above was awaiting owns `recognitionTask` and `currentTranscript` by
        // now, so cancelling here would kill the new recording, and returning the
        // transcript would hand this caller the new session's words.
        guard sessionID == stoppingSession else {
            print("[TranscriptionEngine] A newer session started; leaving it alone")
            return ""
        }

        // Cancel recognition task and give it time to clean up
        recognitionTask?.cancel()
        try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms for cleanup

        recognitionTask = nil
        teardownSession()

        // Append any remaining volatile text
        if !volatileText.isEmpty {
            currentTranscript += volatileText
            volatileText = ""
        }

        print("[TranscriptionEngine] Recording stopped. Final transcript: \(currentTranscript.prefix(50))...")
        return currentTranscript
    }

    /// Cancel recording without returning transcript
    func cancelRecording(owner: SessionOwner = .dictation) {
        guard isRecording else { return }

        guard self.owner == owner else {
            print("[TranscriptionEngine] \(owner.rawValue) tried to cancel a \(self.owner?.rawValue ?? "?") session")
            return
        }

        print("[TranscriptionEngine] Cancelling recording...")
        isRecording = false
        self.owner = nil
        sessionID = UUID()

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
            print("[TranscriptionEngine] Recognition task started")
            do {
                for try await result in transcriber.results {
                    // Check for cancellation
                    guard !Task.isCancelled else {
                        print("[TranscriptionEngine] Recognition task cancelled")
                        break
                    }

                    let text = String(result.text.characters)

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
            } catch {
                print("[TranscriptionEngine] Recognition error: \(error)")
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
