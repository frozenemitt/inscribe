import AVFoundation
import Foundation

#if os(macOS)
import CoreAudio
#endif

/// Non-actor-isolated audio capture helper
/// AVAudioEngine callbacks work better without MainActor isolation
final class AudioCaptureHelper: @unchecked Sendable {
    private var audioEngine: AVAudioEngine?
    private var outputContinuation: AsyncStream<AudioData>.Continuation?

    private(set) var isRunning = false

    init() {}

    /// Start capturing audio and return a stream of audio buffers
    /// - Parameter preferredDeviceUID: CoreAudio UID of the microphone to record from,
    ///   or "default" to follow the system setting.
    func startCapture(preferredDeviceUID: String = "default") throws -> AsyncStream<AudioData> {
        print("[AudioCaptureHelper] Starting capture...")

        #if os(iOS)
        // Setup iOS audio session
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        print("[AudioCaptureHelper] iOS audio session configured")
        #endif

        // Create fresh engine
        let engine = AVAudioEngine()
        self.audioEngine = engine

        // Reset to clean state
        engine.reset()

        let inputNode = engine.inputNode

        #if os(macOS)
        // Must happen before the format is read: changing the device changes the
        // format, and a tap installed against the old one gets silence.
        selectInputDevice(uid: preferredDeviceUID, on: inputNode)
        #endif

        let format = inputNode.outputFormat(forBus: 0)

        print("[AudioCaptureHelper] Input format: \(format)")

        guard format.sampleRate > 0 && format.channelCount > 0 else {
            throw AudioCaptureError.invalidFormat
        }

        // Create stream with makeStream for immediate continuation
        let (stream, continuation) = AsyncStream<AudioData>.makeStream(bufferingPolicy: .unbounded)
        self.outputContinuation = continuation

        // Install tap
        var tapCount = 0
        inputNode.installTap(
            onBus: 0,
            bufferSize: 4096,
            format: format
        ) { [weak self] buffer, time in
            tapCount += 1
            if tapCount <= 5 {
                print("[AudioCaptureHelper] Tap callback #\(tapCount), frames: \(buffer.frameLength)")
            }
            let audioData = AudioData(buffer: buffer, time: time)
            self?.outputContinuation?.yield(audioData)
        }
        print("[AudioCaptureHelper] Tap installed")

        // Start engine
        engine.prepare()
        try engine.start()
        isRunning = engine.isRunning
        print("[AudioCaptureHelper] Engine started, running: \(isRunning)")

        return stream
    }

    #if os(macOS)
    /// Point the engine's input at a specific microphone.
    ///
    /// Silently leaves the system default in place when the device has been unplugged,
    /// which beats refusing to record at all.
    private func selectInputDevice(uid: String, on inputNode: AVAudioInputNode) {
        guard uid != AudioInputDevice.systemDefaultUID else { return }

        // Resolved by UID rather than looked up in the device list: the meeting input
        // is a private aggregate, which deliberately does not appear there.
        guard let resolvedID = AudioDeviceCatalog.resolveDeviceID(uid: uid) else {
            print("[AudioCaptureHelper] Device \(uid) not connected, using system default")
            return
        }
        let deviceName = AudioDeviceCatalog.device(forUID: uid)?.name ?? uid

        guard let audioUnit = inputNode.audioUnit else {
            print("[AudioCaptureHelper] No audio unit on the input node")
            return
        }

        var deviceID = resolvedID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        if status == noErr {
            print("[AudioCaptureHelper] Recording from \(deviceName)")
        } else {
            print("[AudioCaptureHelper] Could not select \(deviceName), OSStatus \(status)")
        }
    }
    #endif

    /// Stop capturing audio
    func stopCapture() {
        print("[AudioCaptureHelper] Stopping capture...")

        guard let engine = audioEngine else {
            print("[AudioCaptureHelper] No engine to stop")
            return
        }

        if engine.isRunning {
            engine.stop()
        }
        engine.inputNode.removeTap(onBus: 0)

        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            print("[AudioCaptureHelper] iOS audio session deactivated")
        } catch {
            print("[AudioCaptureHelper] Warning: Failed to deactivate audio session: \(error)")
        }
        #endif

        outputContinuation?.finish()
        outputContinuation = nil
        audioEngine = nil
        isRunning = false

        print("[AudioCaptureHelper] Capture stopped")
    }

    deinit {
        stopCapture()
    }
}

enum AudioCaptureError: Error {
    case invalidFormat
    case engineNotRunning
}
