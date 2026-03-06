import Foundation

#if os(macOS)
import AppKit
#endif

/// Discovers available system sounds and manages custom imported sounds
@MainActor
@Observable
final class SoundCatalog {

    // MARK: - Constants

    /// Sentinel value representing silence (no sound)
    static let noneID = "none"

    /// Prefix for custom sound identifiers
    static let customPrefix = "custom:"

    // MARK: - Sound Item

    struct SoundItem: Identifiable, Hashable {
        let id: String
        let displayName: String
        let isCustom: Bool
    }

    // MARK: - State

    private(set) var systemSounds: [SoundItem] = []
    private(set) var customSounds: [SoundItem] = []

    #if os(macOS)
    private var previewingSound: NSSound?
    #endif

    /// All available sounds: None + system + custom
    var allSounds: [SoundItem] {
        [SoundItem(id: Self.noneID, displayName: "None", isCustom: false)]
        + systemSounds
        + customSounds
    }

    // MARK: - Singleton

    static let shared = SoundCatalog()

    private init() {
        loadSystemSounds()
        loadCustomSounds()
    }

    // MARK: - System Sounds Discovery

    #if os(macOS)
    private func loadSystemSounds() {
        let path = "/System/Library/Sounds"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: path) else { return }

        systemSounds = files
            .filter { $0.hasSuffix(".aiff") }
            .map { filename in
                let name = (filename as NSString).deletingPathExtension
                return SoundItem(id: name, displayName: name, isCustom: false)
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
    #else
    private func loadSystemSounds() {
        // iOS doesn't support named system sounds
    }
    #endif

    // MARK: - Custom Sounds

    private var customSoundsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Inscribe", isDirectory: true)
            .appendingPathComponent("Sounds", isDirectory: true)
    }

    private func loadCustomSounds() {
        let dir = customSoundsDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        ) else { return }

        let audioExtensions: Set<String> = ["aiff", "wav", "mp3", "caf", "m4a"]

        customSounds = files
            .filter { audioExtensions.contains($0.pathExtension.lowercased()) }
            .map { url in
                SoundItem(
                    id: "\(Self.customPrefix)\(url.lastPathComponent)",
                    displayName: url.deletingPathExtension().lastPathComponent,
                    isCustom: true
                )
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Import a sound file into the custom sounds directory
    func importSound(from sourceURL: URL) throws {
        let dir = customSoundsDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let destination = dir.appendingPathComponent(sourceURL.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }

        try FileManager.default.copyItem(at: sourceURL, to: destination)
        loadCustomSounds()
    }

    /// Delete a custom sound by its identifier
    func deleteCustomSound(id: String) throws {
        guard id.hasPrefix(Self.customPrefix) else { return }
        let filename = String(id.dropFirst(Self.customPrefix.count))
        let url = customSoundsDirectory.appendingPathComponent(filename)
        try FileManager.default.removeItem(at: url)
        loadCustomSounds()
    }

    // MARK: - Playback

    #if os(macOS)
    /// Preview a sound (stops any currently previewing sound first)
    func preview(_ soundId: String) {
        previewingSound?.stop()
        previewingSound = nil

        guard soundId != Self.noneID else { return }
        let sound = makeNSSound(for: soundId)
        sound?.play()
        previewingSound = sound
    }

    /// Create an NSSound instance for the given sound identifier
    func makeNSSound(for soundId: String) -> NSSound? {
        guard soundId != Self.noneID else { return nil }

        if soundId.hasPrefix(Self.customPrefix) {
            let filename = String(soundId.dropFirst(Self.customPrefix.count))
            let url = customSoundsDirectory.appendingPathComponent(filename)
            return NSSound(contentsOf: url, byReference: true)
        } else {
            return NSSound(named: soundId)
        }
    }
    #endif
}
