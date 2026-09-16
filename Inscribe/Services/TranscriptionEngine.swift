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

    /// Loudness per frequency band, 0 to 1, low to high.
    ///
    /// One value per bar of the dictation overlay's band, read off the buffers already
    /// on their way to the analyzer so nothing opens the microphone twice. Empty until
    /// a recording starts, and not computed at all when nothing is drawing it.
    private(set) var spectrum: [Double] = []

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

    /// Rare, and worth keeping: a dictation that goes wrong in a launched app leaves
    /// no other trace, because `print` reaches nobody outside Xcode.
    nonisolated static let log = Logger(subsystem: "com.inscribe.app", category: "Dictation")

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
    /// - Parameter publishesSpectrum: whether anything is going to draw the band. The
    ///   Fourier transform behind it runs on every buffer, and running it for a panel
    ///   nobody has switched on is work spent on a picture that is never drawn.
    func startRecording(
        owner: SessionOwner = .dictation,
        contextualStrings: [String] = [],
        inputDeviceUID: String = "default",
        publishesSpectrum: Bool = false
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



        // How long the key press waits before a word can be spoken. Everything below
        // runs before the microphone is open: the locale, the transcriber, the
        // analyzer, the asset check, the format negotiation.
        let startedAt = ContinuousClock.now

        // A previous start that threw part-way leaves an analyzer and a capture
        // helper alive with isRecording still false, which no stop path will ever
        // reach — both guard on isRecording. Clear that before building anything.
        teardownSession()

        error = nil
        currentTranscript = ""
        volatileText = ""
        timedSegments = []
        spectrum = []

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

        // Start processing task to convert and feed audio to analyzer
        let analyzerContinuation = analyzerInputContinuation
        let targetFormat = analyzerFormat!

        let tap = audioTap

        audioProcessingTask = Task.detached(priority: .userInitiated) { [weak self] in
            let converter = BufferConverter()
            let spectrumAnalyzer = publishesSpectrum
                ? SpectrumAnalyzer(bandCount: TranscriptionEngine.spectrumBandCount)
                : nil
            var bufferCount = 0

            for await audioData in audioStream {
                bufferCount += 1

                // Hand the untouched buffer to any second consumer before conversion,
                // so diarization sees the same audio the transcriber does.
                tap?(audioData.buffer)

                if let bands = spectrumAnalyzer?.bands(from: audioData.buffer) {
                    await MainActor.run { self?.applySpectrum(bands) }
                }

                do {
                    let converted = try converter.convertBuffer(audioData.buffer, to: targetFormat)
                    let input = AnalyzerInput(buffer: converted)
                    analyzerContinuation?.yield(input)
                } catch {
                    Self.log.error("conversion failed on buffer #\(bufferCount, privacy: .public): \(error, privacy: .public)")
                }
            }
        }

        phase = .recording
        let setup = ContinuousClock.now - startedAt
        let seconds = Double(setup.components.seconds) + Double(setup.components.attoseconds) / 1e18
        Self.log.notice("recording started for \(owner.rawValue, privacy: .public), ready in \(seconds, format: .fixed(precision: 3), privacy: .public)s")
    }

    /// Stop recording and return the final transcript
    @discardableResult
    func stopRecording(owner: SessionOwner = .dictation) async throws -> String {
        guard phase == .recording else {
            Log.dictation.notice("Not recording, ignoring stop request")
            return currentTranscript
        }

        // Refuse to end someone else's session: a dictation hotkey must not stop a
        // meeting that happens to be using the same engine.
        guard self.owner == owner else {
            Self.log.error("\(owner.rawValue, privacy: .public) tried to stop a \(self.owner?.rawValue ?? "none", privacy: .public) session")
            return currentTranscript
        }

        // Held, not released: nothing else may take the engine until this session has
        // finished handing back its words.
        phase = .stopping
        Log.dictation.notice("STEP 1 entered stopRecording")

        // Stop audio capture helper. This finishes the audio stream, so the task
        // below runs out of buffers on its own.
        audioCaptureHelper?.stopCapture()
        audioCaptureHelper = nil

        // Awaited rather than cancelled. An AsyncStream iterator throws away whatever
        // is still buffered when it is cancelled, and what is still buffered is
        // always the end of the sentence the user just spoke.
        Log.dictation.notice("STEP 2 capture stopped")
        let audioTask = audioProcessingTask
        if await !Self.bounded(2, { _ = await audioTask?.value }) {
            Self.log.error("audio did not drain in 2s — cancelling")
            audioProcessingTask?.cancel()
        }
        Log.dictation.notice("STEP 3 audio drained")
        audioProcessingTask = nil

        // Finalize transcription

        analyzerInputContinuation?.finish()

        Log.dictation.notice("STEP 4 input finished")
        var finalized = true
        let analyzer = speechAnalyzer
        let finishedInTime = await Self.bounded(3) {
            do {
                try await analyzer?.finalizeAndFinishThroughEndOfInput()
            } catch {
                Self.log.error("finalize failed: \(error, privacy: .public)")
            }
        }

        Log.dictation.notice("STEP 5 finalize returned")
        if !finishedInTime {
            // Seen on recordings of a few tens of milliseconds: finalization simply
            // never returns. Waiting forever costs the whole engine.
            finalized = false
            Self.log.error("finalize did not return in 3s — giving up on the tail")
            self.error = .transcriptionFailed("The recogniser did not finish.")
        }
        // Drained rather than cancelled, for the same reason the audio stream above is.
        //
        // The transcriber holds a whole dictation as unconfirmed text and only turns it
        // into finalized runs when `finalizeAndFinishThroughEndOfInput` asks it to. That
        // call also ends the results stream, so awaiting the task here consumes every
        // one of those runs and returns when the stream does. Cancelling instead broke
        // the loop on its next turn and threw the entire dictation away, leaving only
        // whatever volatile snapshot happened to be held — a word or two of a long
        // sentence, delivered without any error to say the rest was dropped.
        //
        // A finalize that threw leaves no promise that the stream will end, so that one
        // case still cancels.

        if finalized {
            // Bounded, because this is the one place a stall costs everything after
            // it. The stream is supposed to end when finalization does; when it did
            // not, this method never returned, the engine stayed in `.stopping`, and
            // every later hotkey press was refused by the busy guard without a word.
            // A dictation that ends a little short beats an app that stops answering.
            let task = recognitionTask
            let drained = await Self.bounded(2) { _ = try? await task?.value }

            if !drained {
                Self.log.error("results did not drain in 2s — cancelling, the tail may be short")
                recognitionTask?.cancel()
            }
        } else {
            recognitionTask?.cancel()
        }

        Log.dictation.notice("STEP 6 results drained")
        recognitionTask = nil
        teardownSession()

        // Append any remaining volatile text
        if !volatileText.isEmpty {
            currentTranscript += volatileText
            volatileText = ""
        }

        release()

        spectrum = []
        Self.log.notice("recording stopped, delivering \(self.currentTranscript.count, privacy: .public) chars")
        return currentTranscript
    }

    /// How many bars the overlay's band has.
    nonisolated static let spectrumBandCount = 48

    /// Fold new band readings in, fast to rise and slower to fall.
    ///
    /// Same reason as the level: without it each bar chases the noise between
    /// syllables and the band looks like static rather than a voice.
    private func applySpectrum(_ reading: [Double]) {
        guard reading.count == Self.spectrumBandCount else { return }

        if spectrum.count != reading.count {
            spectrum = reading
            return
        }

        for index in reading.indices {
            let current = spectrum[index]
            let next = reading[index]
            spectrum[index] = next > current
                ? current + (next - current) * 0.85
                : current + (next - current) * 0.5
        }
    }

    /// Run `work`, giving up after `seconds`. False when it ran out of time.
    ///
    /// Every await in the stop path needs one. A dictation that ends short is a bad
    /// outcome; an engine stuck in `.stopping` refuses every recording after it,
    /// without a sound, until the app is relaunched — which is what a hung await here
    /// looks like from the outside: a hotkey that has died.
    private nonisolated static func bounded(
        _ seconds: Double,
        _ work: @escaping @Sendable () async -> Void
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await work()
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
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
            Self.log.error("\(owner.rawValue, privacy: .public) tried to cancel a \(self.owner?.rawValue ?? "none", privacy: .public) session")
            return
        }

        Self.log.notice("recording cancelled")
        release()

        audioCaptureHelper?.stopCapture()
        audioCaptureHelper = nil
        audioProcessingTask?.cancel()
        audioProcessingTask = nil
        analyzerInputContinuation?.finish()
        teardownSession()

        currentTranscript = ""
        volatileText = ""
        spectrum = []
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
        Log.dictation.notice("Microphone auth status: \(audioStatus.rawValue, privacy: .public) (0=notDetermined, 1=restricted, 2=denied, 3=authorized)")

        switch audioStatus {
        case .authorized:
            Log.dictation.notice("Microphone already authorized")
            return true
        case .notDetermined:
            Log.dictation.notice("Requesting microphone access...")
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            Log.dictation.notice("Microphone access granted: \(granted, privacy: .public)")
            if !granted {
                error = .notAuthorized
            }
            return granted
        case .denied, .restricted:
            Log.dictation.error("Microphone access denied or restricted")
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
        Log.dictation.notice("Setting up speech recognition...")

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
            // `.fastResults` is what puts words on the overlay while you are still
            // speaking. Without it the transcriber holds its unconfirmed text back and
            // the preview trails several seconds behind the voice.
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange]
        )

        guard let transcriber = speechTranscriber else {
            throw TranscriptionEngineError.setupFailed("Failed to create SpeechTranscriber")
        }

        // Create analyzer with transcriber
        //
        // Run at the priority of something the user is waiting on, because they are:
        // the words appear on the overlay as fast as this work is scheduled. Keeping
        // the model for the life of the process spares every dictation after the first
        // the cost of loading it again.
        speechAnalyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: .init(priority: .userInitiated, modelRetention: .processLifetime)
        )

        // Bias the recognizer toward the user's own vocabulary. Unlike a post-hoc
        // replacement this changes what the model is listening for, which is what
        // proper nouns need.
        let hints = contextualStrings.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if !hints.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = hints
            do {
                try await speechAnalyzer?.setContext(context)
                Log.dictation.notice("Applied \(hints.count, privacy: .public) vocabulary hints")
            } catch {
                // Worth continuing without: hints improve accuracy, they are not required.
                Log.dictation.error("Could not apply vocabulary hints: \(error, privacy: .public)")
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
            var resultCount = 0
            do {
                for try await result in transcriber.results {
                    // Check for cancellation
                    guard !Task.isCancelled else {
                        // The one line that says whether stopping threw words away: a
                        // stream that ended on its own never reaches this.
                        Self.log.error("recognition task cancelled after \(resultCount, privacy: .public) results — anything still queued was dropped")
                        break
                    }

                    let text = String(result.text.characters)
                    resultCount += 1

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
                Self.log.error("recognition failed after \(resultCount, privacy: .public) results: \(error, privacy: .public)")
                await MainActor.run {
                    self?.error = .transcriptionFailed(error.localizedDescription)
                }
            }
        }

        // Start analyzer
        try await speechAnalyzer?.start(inputSequence: inputStream)
        Log.dictation.notice("Speech recognition setup complete")
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
    /// Resolved once per run. Asking the system which locales it can transcribe takes
    /// tens of milliseconds, and the answer cannot change while the app is open — but
    /// it was being asked again on every single key press, before the microphone
    /// opened, while the user waited to speak.
    private static var cachedLocale: Locale?

    private func resolveSupportedLocale() async throws -> Locale {
        if let cached = Self.cachedLocale { return cached }

        let supported = await SpeechTranscriber.supportedLocales

        for candidate in Self.fallbackLocales
        where supported.contains(where: { $0.identifier(.bcp47) == candidate.identifier(.bcp47) }) {
            Self.cachedLocale = candidate
            return candidate
        }

        throw TranscriptionEngineError.localeNotSupported
    }

    /// Whether the model has already been found and the locale reserved this run.
    private static var assetsReady = false

    private func ensureModelAvailable(transcriber: SpeechTranscriber, locale: Locale) async throws {
        // Both questions below are answered by the system and neither answer changes
        // while the app runs, so they are asked once rather than on every key press.
        // A model that needs downloading still downloads, and only the first recording
        // waits for it.
        if Self.assetsReady { return }

        if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            Log.dictation.notice("Downloading speech model...")
            try await downloader.downloadAndInstall()
        }

        let reservedLocales = await AssetInventory.reservedLocales
        if !reservedLocales.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
            try await AssetInventory.reserve(locale: locale)
        }

        Self.assetsReady = true
        Log.dictation.notice("Using locale: \(locale.identifier, privacy: .public)")
    }

    /// Do the once-per-run work before the user asks for it.
    ///
    /// Called at launch so even the first dictation opens its microphone without
    /// waiting for the locale list and the asset inventory.
    func prepare() async {
        guard let locale = try? await resolveSupportedLocale() else { return }
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange]
        )
        try? await ensureModelAvailable(transcriber: transcriber, locale: locale)
        Log.dictation.notice("speech stack ready")
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
            Log.dictation.notice("Deallocating...")
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
