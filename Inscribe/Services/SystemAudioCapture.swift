import Foundation

#if os(macOS)
import CoreAudio
import AVFoundation
import Accelerate
import os

/// Captures what the Mac is playing, alongside the microphone.
///
/// Meeting mode without this hears only your half of a call: `AVAudioEngine.inputNode`
/// is the microphone, and everyone dialling in arrives through system *output*, which
/// it never sees. Speaker separation on a remote meeting is meaningless until both
/// sides are in the recording.
///
/// The mechanism is a Core Audio process tap plus an aggregate device. The tap exposes
/// system playback as an input; the aggregate binds it to the microphone so both
/// arrive on one clock, already sample-aligned. Mixing two independently clocked
/// devices in software would drift, and drift wrecks the timestamps diarization
/// depends on.
///
/// Sendable so that building and destroying the device can run off the main thread:
/// each is a round trip to the audio server that can take hundreds of milliseconds,
/// and on the main thread the whole app froze for it. Unchecked, because the safety
/// comes from the one caller, a meeting, whose steps run one after another and each
/// wait for the last; no two calls on one instance ever overlap.
final class SystemAudioCapture: @unchecked Sendable {

    private static let log = Logger(subsystem: "com.inscribe.app", category: "SystemAudio")

    /// Our own process, excluded from the tap so Inscribe's feedback sounds and any
    /// meeting playback do not get recorded back into the meeting.
    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateID: AudioDeviceID = kAudioObjectUnknown

    /// UID of the aggregate device, for handing to `AVAudioEngine`.
    private(set) var aggregateUID: String?

    var isActive: Bool { aggregateID != kAudioObjectUnknown }

    // MARK: - Lifecycle

    /// Build a device carrying both the microphone and system playback.
    ///
    /// - Parameter microphoneUID: The mic to include, or nil for the system default.
    /// - Returns: The aggregate device's UID.
    @discardableResult
    func start(microphoneUID: String?) throws -> String {
        stop()

        let tap = try createGlobalTap()
        tapID = tap.id

        // The chosen microphone only if it is still connected, and the default input
        // otherwise. An unplugged microphone keeps its UID, and an aggregate that lists
        // a device which is not there carries only the tap: the call without the user.
        var chosenUID = microphoneUID
        if let microphoneUID, AudioDeviceCatalog.resolveDeviceID(uid: microphoneUID) == nil {
            Self.log.notice("Chosen microphone is not connected; using the default input")
            chosenUID = nil
        }
        let micUID = chosenUID ?? Self.defaultInputUID()
        let uid = "com.inscribe.aggregate.\(UUID().uuidString)"

        var subDevices: [[String: Any]] = []
        if let micUID {
            subDevices.append([kAudioSubDeviceUIDKey: micUID])
        } else {
            Self.log.notice("No microphone available; recording system audio only")
        }

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Inscribe Meeting Input",
            kAudioAggregateDeviceUIDKey: uid,
            // Private: this device is ours for the duration, and should never appear
            // in the user's Sound settings or other apps' device pickers.
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tap.uid
                ]
            ],
            kAudioAggregateDeviceTapAutoStartKey: true
        ]

        // The microphone is the clock source: it is the device that cannot be
        // resampled without losing real audio, so everything else drifts to match it.
        var finalDescription = description
        if let micUID {
            finalDescription[kAudioAggregateDeviceMainSubDeviceKey] = micUID
        }

        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(finalDescription as CFDictionary, &deviceID)

        guard status == noErr, deviceID != kAudioObjectUnknown else {
            destroyTap()
            throw SystemAudioError.aggregateCreationFailed(status)
        }

        aggregateID = deviceID
        aggregateUID = uid
        Self.log.notice("Aggregate input ready (mic + system audio)")
        return uid
    }

    /// Tear down the aggregate device and the tap.
    ///
    /// Both leak system-wide if left behind — an abandoned private aggregate survives
    /// the app that made it.
    func stop() {
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        aggregateUID = nil
        destroyTap()
    }

    deinit {
        stop()
    }

    private func destroyTap() {
        guard tapID != kAudioObjectUnknown else { return }
        AudioHardwareDestroyProcessTap(tapID)
        tapID = kAudioObjectUnknown
    }

    // MARK: - Tap

    private func createGlobalTap() throws -> (id: AudioObjectID, uid: String) {
        // Everything the Mac plays, minus ourselves.
        let description = CATapDescription(
            stereoGlobalTapButExcludeProcesses: Self.ownProcessObjects()
        )
        // Leave playback audible: muting the tap would silence the call for the user.
        description.muteBehavior = .unmuted
        description.isPrivate = true
        description.name = "Inscribe Meeting Tap"

        var id = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &id)

        guard status == noErr, id != kAudioObjectUnknown else {
            throw SystemAudioError.tapCreationFailed(status)
        }

        guard let uid = Self.stringProperty(kAudioTapPropertyUID, from: id) else {
            AudioHardwareDestroyProcessTap(id)
            throw SystemAudioError.tapCreationFailed(status)
        }

        return (id, uid)
    }

    // MARK: - CoreAudio Helpers

    /// Our own process, as Core Audio identifies it.
    ///
    /// The exclusion list wants audio process objects, not Unix pids — passing a pid
    /// silently excludes whatever unrelated object happens to share that number, so
    /// Inscribe's own sounds would end up recorded into the meeting.
    private static func ownProcessObjects() -> [AudioObjectID] {
        var pid = pid_t(ProcessInfo.processInfo.processIdentifier)
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &pid,
            &size,
            &objectID
        )

        guard status == noErr, objectID != kAudioObjectUnknown else {
            log.notice("Could not resolve our own audio process object; tap will include our own output")
            return []
        }
        return [objectID]
    }

    private static func defaultInputUID() -> String? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr else { return nil }

        return stringProperty(kAudioDevicePropertyDeviceUID, from: deviceID)
    }

    private static func stringProperty(
        _ selector: AudioObjectPropertySelector,
        from objectID: AudioObjectID
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)

        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer)
        }

        guard status == noErr else { return nil }
        let result = value as String
        return result.isEmpty ? nil : result
    }

    // MARK: - Permission

    /// Whether macOS will let this process tap system audio.
    ///
    /// Determined by trying: there is no query API, and a refused tap simply fails to
    /// create. The attempt is what triggers the system's permission prompt.
    static func checkAvailability() -> Bool {
        let description = CATapDescription(
            stereoGlobalTapButExcludeProcesses: ownProcessObjects()
        )
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var id = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &id)

        if status == noErr, id != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(id)
            return true
        }

        log.notice("System audio tap unavailable, OSStatus \(status)")
        return false
    }

    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }
}

/// Notices whether any system audio has reached the meeting.
///
/// A refused permission may not refuse the tap. `checkAvailability()` creates one, sees
/// it succeed and reports the permission granted, and the meeting then records the tap
/// faithfully: silence, for the whole call. Whether macOS behaves that way could not be
/// confirmed here, so this is the cheapest signal that catches it either way: if the
/// tap's channels hold nothing but silence for the first minute, the meeting says so.
///
/// Silence is also what a tap hears before anyone on the call speaks, which is why the
/// warning waits a minute and is worded as something to check rather than a verdict.
final class SystemAudioLevelProbe: @unchecked Sendable {

    /// Quieter than this is silence: about -100 dBFS, below any real playback.
    private static let threshold: Float = 0.00001

    private let lock = NSLock()
    private var heard = false

    var hasHeardSound: Bool {
        lock.lock()
        defer { lock.unlock() }
        return heard
    }

    func reset() {
        lock.lock()
        heard = false
        lock.unlock()
    }

    /// Look for sound on the tap's channels, which the aggregate puts last: a stereo
    /// pair after the microphone's own.
    ///
    /// Runs on the audio thread for every buffer until the first sound, then only reads
    /// the flag.
    func inspect(_ buffer: AVAudioPCMBuffer) {
        guard !hasHeardSound else { return }

        let channels = Int(buffer.format.channelCount)
        let frames = vDSP_Length(buffer.frameLength)
        guard channels > 0, frames > 0 else { return }

        // A format this cannot read is not evidence of silence, so it counts as heard
        // rather than raising a warning nobody can act on.
        guard let data = buffer.floatChannelData else {
            markHeard()
            return
        }

        var peak: Float = 0
        for channel in max(0, channels - 2)..<channels {
            var channelPeak: Float = 0
            if buffer.format.isInterleaved {
                vDSP_maxmgv(data[0] + channel, vDSP_Stride(channels), &channelPeak, frames)
            } else {
                vDSP_maxmgv(data[channel], 1, &channelPeak, frames)
            }
            peak = max(peak, channelPeak)
        }

        if peak > Self.threshold {
            markHeard()
        }
    }

    private func markHeard() {
        lock.lock()
        heard = true
        lock.unlock()
    }
}

enum SystemAudioError: LocalizedError {
    case tapCreationFailed(OSStatus)
    case aggregateCreationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .tapCreationFailed(let status):
            "Could not capture system audio (OSStatus \(status)). Grant Inscribe permission to record system audio in System Settings."
        case .aggregateCreationFailed(let status):
            "Could not combine the microphone with system audio (OSStatus \(status))."
        }
    }
}

import AppKit
#endif
