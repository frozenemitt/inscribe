import Foundation

#if os(macOS)
import CoreAudio
import AVFoundation
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
final class SystemAudioCapture {

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

        let micUID = microphoneUID ?? Self.defaultInputUID()
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
