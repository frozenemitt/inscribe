import Foundation

#if os(macOS)
import CoreAudio
import AVFoundation

/// An audio input the user can record from.
struct AudioInputDevice: Identifiable, Hashable, Sendable {
    /// CoreAudio's persistent identifier, stored in settings. Survives reboots and
    /// device renames, unlike the numeric AudioDeviceID.
    let uid: String
    let name: String
    let deviceID: AudioDeviceID

    var id: String { uid }

    /// The sentinel meaning "whatever macOS is currently set to".
    static let systemDefaultUID = "default"
}

/// Lists the microphones available to record from.
enum AudioDeviceCatalog {

    /// Every device that has at least one input channel.
    static func inputDevices() -> [AudioInputDevice] {
        allDeviceIDs()
            .filter { hasInputChannels($0) }
            .compactMap { id in
                guard let uid = stringProperty(kAudioDevicePropertyDeviceUID, for: id),
                      let name = stringProperty(kAudioObjectPropertyName, for: id) else {
                    return nil
                }
                return AudioInputDevice(uid: uid, name: name, deviceID: id)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Resolve a stored UID back to a live device, or nil for the system default.
    static func device(forUID uid: String) -> AudioInputDevice? {
        guard uid != AudioInputDevice.systemDefaultUID else { return nil }
        return inputDevices().first { $0.uid == uid }
    }

    /// The name macOS would use right now, for the "System Default" menu entry.
    static func systemDefaultName() -> String {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr else { return "System Default" }
        return stringProperty(kAudioObjectPropertyName, for: deviceID) ?? "System Default"
    }

    /// Resolve a UID straight to a device id.
    ///
    /// Unlike `device(forUID:)`, this does not scan the device list — a private
    /// aggregate does not appear there by design, and the meeting input is one.
    static func resolveDeviceID(uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var cfUID = uid as CFString
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = withUnsafeMutablePointer(to: &cfUID) { pointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString>.size),
                pointer,
                &size,
                &deviceID
            )
        }

        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    // MARK: - CoreAudio Plumbing

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }

        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &ids
        ) == noErr else { return [] }

        return ids
    }

    /// A device is an input if its input scope reports any channels at all.
    private static func hasInputChannels(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return false }

        let bufferList = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferList.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, bufferList) == noErr else {
            return false
        }

        let list = UnsafeMutableAudioBufferListPointer(
            bufferList.assumingMemoryBound(to: AudioBufferList.self)
        )
        return list.contains { $0.mNumberChannels > 0 }
    }

    private static func stringProperty(
        _ selector: AudioObjectPropertySelector,
        for deviceID: AudioDeviceID
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)

        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }

        guard status == noErr else { return nil }
        let result = value as String
        return result.isEmpty ? nil : result
    }
}
#endif
