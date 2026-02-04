import AVFoundation
import Combine
import Foundation
import Speech
import Observation

/// Unified transcription engine for background voice-to-text
/// Uses Apple's modern SpeechAnalyzer API (iOS 26+/macOS 26+)
@MainActor
@Observable
final class TranscriptionEngine {

    // MARK: - Published State

    private(set) var isRecording = false
    private(set) var currentTranscript = ""
    private(set) var volatileText = ""  // Live, unconfirmed text
    private(set) var error: TranscriptionEngineError?

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

    init() {}

    // MARK: - Public API

    /// Start recording and transcribing audio
    func startRecording() async throws {
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

        // Setup speech recognition first
        try await setupSpeechRecognition()

        // Start audio capture using non-MainActor helper (like original Recorder)
        let helper = AudioCaptureHelper()
        self.audioCaptureHelper = helper

        let audioStream = try helper.startCapture()

        // Start processing task to convert and feed audio to analyzer
        let analyzerContinuation = analyzerInputContinuation
        let targetFormat = analyzerFormat!

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

        isRecording = true
        print("[TranscriptionEngine] Recording started successfully")
    }

    /// Stop recording and return the final transcript
    @discardableResult
    func stopRecording() async throws -> String {
        guard isRecording else {
            print("[TranscriptionEngine] Not recording, ignoring stop request")
            return currentTranscript
        }

        print("[TranscriptionEngine] Stopping recording...")
        isRecording = false

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
    func cancelRecording() {
        guard isRecording else { return }

        print("[TranscriptionEngine] Cancelling recording...")
        isRecording = false

        audioCaptureHelper?.stopCapture()
        audioCaptureHelper = nil
        audioProcessingTask?.cancel()
        audioProcessingTask = nil
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

    // MARK: - Audio Format Conversion

    /// Convert Float32 audio buffer to Int16 format for SpeechAnalyzer
    private static func convertFloat32ToInt16(buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let floatData = buffer.floatChannelData?[0] else { return nil }

        let frameCount = buffer.frameLength

        guard let int16Buffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else {
            return nil
        }
        int16Buffer.frameLength = frameCount

        guard let int16Data = int16Buffer.int16ChannelData?[0] else { return nil }

        // Convert Float32 [-1.0, 1.0] to Int16 [-32768, 32767]
        for i in 0..<Int(frameCount) {
            let sample = floatData[i]
            // Clamp to [-1.0, 1.0] then scale to Int16 range
            let clamped = max(-1.0, min(1.0, sample))
            int16Data[i] = Int16(clamped * 32767.0)
        }

        return int16Buffer
    }

    // MARK: - Cleanup

    private func cleanup() {
        audioCaptureHelper = nil
        audioProcessingTask = nil
        speechTranscriber = nil
        speechAnalyzer = nil
        analyzerInputContinuation = nil
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
        }
    }
}
