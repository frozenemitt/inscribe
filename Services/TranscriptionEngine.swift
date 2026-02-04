import AVFoundation
import Foundation
import Speech

/// Unified transcription engine for background voice-to-text
/// Uses Apple's modern SpeechAnalyzer API (iOS 26+/macOS 26+)
@MainActor
public final class TranscriptionEngine: ObservableObject {

    // MARK: - Published State

    @Published public private(set) var isRecording = false
    @Published public private(set) var currentTranscript = ""
    @Published public private(set) var volatileText = ""  // Live, unconfirmed text
    @Published public private(set) var error: TranscriptionEngineError?

    // MARK: - Audio Components

    private var audioEngine: AVAudioEngine?
    private var audioStreamContinuation: AsyncStream<AudioData>.Continuation?

    // MARK: - Speech Components

    private var speechTranscriber: SpeechTranscriber?
    private var speechAnalyzer: SpeechAnalyzer?
    private var analyzerInputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var recognitionTask: Task<Void, Error>?

    private let bufferConverter = BufferConverter()
    private var analyzerFormat: AVAudioFormat?

    // MARK: - Configuration

    public static let defaultLocale = Locale(
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

    public init() {}

    // MARK: - Public API

    /// Start recording and transcribing audio
    public func startRecording() async throws {
        guard !isRecording else {
            print("[TranscriptionEngine] Already recording, ignoring start request")
            return
        }

        print("[TranscriptionEngine] Starting recording...")
        error = nil
        currentTranscript = ""
        volatileText = ""

        // Check authorization
        guard await checkAuthorization() else {
            throw TranscriptionEngineError.notAuthorized
        }

        // Setup speech recognition
        try await setupSpeechRecognition()

        // Setup and start audio capture
        try await setupAudioEngine()
        try startAudioCapture()

        isRecording = true
        print("[TranscriptionEngine] Recording started successfully")
    }

    /// Stop recording and return the final transcript
    @discardableResult
    public func stopRecording() async throws -> String {
        guard isRecording else {
            print("[TranscriptionEngine] Not recording, ignoring stop request")
            return currentTranscript
        }

        print("[TranscriptionEngine] Stopping recording...")
        isRecording = false

        // Stop audio capture
        stopAudioCapture()

        // Finalize transcription
        analyzerInputContinuation?.finish()

        do {
            try await speechAnalyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            print("[TranscriptionEngine] Error finalizing transcription: \(error)")
            self.error = .transcriptionFailed(error.localizedDescription)
        }

        // Cancel recognition task and give it time to clean up
        recognitionTask?.cancel()
        try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms for cleanup
        recognitionTask = nil

        // Cleanup
        cleanup()

        // Append any remaining volatile text
        if !volatileText.isEmpty {
            currentTranscript += volatileText
            volatileText = ""
        }

        print("[TranscriptionEngine] Recording stopped. Final transcript: \(currentTranscript.prefix(50))...")
        return currentTranscript
    }

    /// Cancel recording without returning transcript
    public func cancelRecording() {
        guard isRecording else { return }

        print("[TranscriptionEngine] Cancelling recording...")
        isRecording = false

        stopAudioCapture()
        analyzerInputContinuation?.finish()
        recognitionTask?.cancel()
        recognitionTask = nil
        cleanup()

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

        switch audioStatus {
        case .authorized:
            return true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted {
                error = .notAuthorized
            }
            return granted
        case .denied, .restricted:
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
    public func requestAuthorization() async -> Bool {
        await checkAuthorization()
    }

    // MARK: - Speech Recognition Setup

    private func setupSpeechRecognition() async throws {
        print("[TranscriptionEngine] Setting up speech recognition...")

        // Create input stream for analyzer
        let (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.analyzerInputContinuation = inputContinuation

        // Create transcriber
        speechTranscriber = SpeechTranscriber(
            locale: Self.defaultLocale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )

        guard let transcriber = speechTranscriber else {
            throw TranscriptionEngineError.setupFailed("Failed to create SpeechTranscriber")
        }

        // Create analyzer with transcriber
        speechAnalyzer = SpeechAnalyzer(modules: [transcriber])

        // Ensure model is available
        try await ensureModelAvailable(transcriber: transcriber)

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
                    await MainActor.run {
                        guard let self = self else { return }
                        if result.isFinal {
                            self.currentTranscript += text
                            self.volatileText = ""
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

    private func ensureModelAvailable(transcriber: SpeechTranscriber) async throws {
        print("[TranscriptionEngine] Ensuring model is available...")

        // Check if download is needed
        if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            print("[TranscriptionEngine] Downloading speech model...")
            try await downloader.downloadAndInstall()
        }

        // Find a supported locale
        let supportedLocales = await SpeechTranscriber.supportedLocales
        var localeToUse: Locale?

        // Try preferred locale first
        if supportedLocales.contains(where: { $0.identifier(.bcp47) == Self.defaultLocale.identifier(.bcp47) }) {
            localeToUse = Self.defaultLocale
        } else {
            // Try fallbacks
            for fallback in Self.fallbackLocales {
                if supportedLocales.contains(where: { $0.identifier(.bcp47) == fallback.identifier(.bcp47) }) {
                    localeToUse = fallback
                    break
                }
            }
        }

        guard let locale = localeToUse else {
            throw TranscriptionEngineError.localeNotSupported
        }

        // Reserve the locale
        let reservedLocales = await AssetInventory.reservedLocales
        if !reservedLocales.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
            try await AssetInventory.reserve(locale: locale)
        }

        print("[TranscriptionEngine] Using locale: \(locale.identifier)")
    }

    // MARK: - Audio Engine Setup

    private func setupAudioEngine() async throws {
        print("[TranscriptionEngine] Setting up audio engine...")

        audioEngine = AVAudioEngine()

        #if os(iOS)
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        #endif

        print("[TranscriptionEngine] Audio engine setup complete")
    }

    private func startAudioCapture() throws {
        guard let audioEngine = audioEngine else {
            throw TranscriptionEngineError.setupFailed("Audio engine not initialized")
        }

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        print("[TranscriptionEngine] Input format: \(recordingFormat)")

        // Install tap on input node
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, _ in
            guard self != nil else { return }

            Task { [weak self] @MainActor in
                guard let self = self else { return }
                do {
                    try await self.processAudioBuffer(buffer)
                } catch {
                    print("[TranscriptionEngine] Buffer processing error: \(error)")
                }
            }
        }

        audioEngine.prepare()
        try audioEngine.start()

        print("[TranscriptionEngine] Audio capture started")
    }

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) async throws {
        guard let analyzerFormat = analyzerFormat else { return }

        let convertedBuffer = try bufferConverter.convertBuffer(buffer, to: analyzerFormat)
        let input = AnalyzerInput(buffer: convertedBuffer)
        analyzerInputContinuation?.yield(input)
    }

    private func stopAudioCapture() {
        guard let audioEngine = audioEngine else {
            print("[TranscriptionEngine] Audio engine not initialized, skipping cleanup")
            return
        }

        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)

        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            print("[TranscriptionEngine] Audio session deactivated")
        } catch {
            print("[TranscriptionEngine] Warning: Failed to deactivate audio session: \(error)")
        }
        #endif

        print("[TranscriptionEngine] Audio capture stopped")
    }

    // MARK: - Cleanup

    private func cleanup() {
        audioEngine = nil
        speechTranscriber = nil
        speechAnalyzer = nil
        analyzerInputContinuation = nil
        analyzerFormat = nil
    }

    deinit {
        print("[TranscriptionEngine] Deallocating...")
        recognitionTask?.cancel()
        if audioEngine?.isRunning == true {
            audioEngine?.stop()
            audioEngine?.inputNode.removeTap(onBus: 0)
        }
        cleanup()
    }
}

// MARK: - Errors

public enum TranscriptionEngineError: Error, LocalizedError {
    case notAuthorized
    case setupFailed(String)
    case transcriptionFailed(String)
    case localeNotSupported

    public var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Microphone access not authorized"
        case .setupFailed(let reason):
            return "Setup failed: \(reason)"
        case .transcriptionFailed(let reason):
            return "Transcription failed: \(reason)"
        case .localeNotSupported:
            return "No supported language locale found"
        }
    }
}
