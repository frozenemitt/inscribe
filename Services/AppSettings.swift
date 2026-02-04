import Foundation
import SwiftUI

/// Lightweight app settings for the background transcription tool
@Observable
public final class AppSettings {

    // MARK: - AI Processing Settings

    /// Whether to process transcription with AI before copying
    public var aiEnabled: Bool {
        didSet { save("aiEnabled", aiEnabled) }
    }

    /// The currently selected prompt ID (nil = use default)
    public var selectedPromptId: UUID? {
        didSet { save("selectedPromptId", selectedPromptId?.uuidString) }
    }

    /// The currently selected AI model ID (nil = use default)
    public var selectedModelId: String? {
        didSet { save("selectedModelId", selectedModelId) }
    }

    // MARK: - Behavior Settings

    /// Whether to automatically copy to clipboard after transcription
    public var copyToClipboardAutomatically: Bool {
        didSet { save("copyToClipboardAutomatically", copyToClipboardAutomatically) }
    }

    /// Whether to play feedback sounds on start/stop
    public var playFeedbackSounds: Bool {
        didSet { save("playFeedbackSounds", playFeedbackSounds) }
    }

    /// Whether to show notifications when transcription completes
    public var showNotifications: Bool {
        didSet { save("showNotifications", showNotifications) }
    }

    // MARK: - Hotkey Settings (macOS only)

    /// The global hotkey combination (stored as string representation)
    public var hotkeyString: String {
        didSet { save("hotkeyString", hotkeyString) }
    }

    // MARK: - Initialization

    public init() {
        // Load saved settings with defaults
        self.aiEnabled = UserDefaults.standard.object(forKey: "aiEnabled") as? Bool ?? true
        self.copyToClipboardAutomatically = UserDefaults.standard.object(forKey: "copyToClipboardAutomatically") as? Bool ?? true
        self.playFeedbackSounds = UserDefaults.standard.object(forKey: "playFeedbackSounds") as? Bool ?? true
        self.showNotifications = UserDefaults.standard.object(forKey: "showNotifications") as? Bool ?? true
        self.hotkeyString = UserDefaults.standard.string(forKey: "hotkeyString") ?? "⌃⌥⌘C"

        // Load optional values
        if let promptIdString = UserDefaults.standard.string(forKey: "selectedPromptId") {
            self.selectedPromptId = UUID(uuidString: promptIdString)
        } else {
            self.selectedPromptId = nil
        }

        self.selectedModelId = UserDefaults.standard.string(forKey: "selectedModelId")

        print("[AppSettings] Loaded settings - AI: \(aiEnabled), Clipboard: \(copyToClipboardAutomatically)")
    }

    // MARK: - Persistence

    private func save(_ key: String, _ value: Any?) {
        if let value = value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // MARK: - Convenience Methods

    /// Reset all settings to defaults
    public func resetToDefaults() {
        aiEnabled = true
        selectedPromptId = nil
        selectedModelId = nil
        copyToClipboardAutomatically = true
        playFeedbackSounds = true
        showNotifications = true
        hotkeyString = "⌃⌥⌘C"

        print("[AppSettings] Reset to defaults")
    }

    /// Check if AI processing should be used for current transcription
    public var shouldProcessWithAI: Bool {
        aiEnabled && selectedPromptId != nil
    }
}

// MARK: - Hotkey Parsing (macOS)

#if os(macOS)
import Carbon

extension AppSettings {
    /// Parse the hotkey string into modifier flags and key code
    /// Returns nil if the hotkey string is invalid
    public func parseHotkey() -> (modifiers: UInt32, keyCode: UInt32)? {
        // Default: Ctrl+Option+Command+C
        // ⌃ = Control, ⌥ = Option, ⌘ = Command, ⇧ = Shift

        var modifiers: UInt32 = 0
        var keyChar: Character?

        for char in hotkeyString {
            switch char {
            case "⌃":
                modifiers |= UInt32(controlKey)
            case "⌥":
                modifiers |= UInt32(optionKey)
            case "⌘":
                modifiers |= UInt32(cmdKey)
            case "⇧":
                modifiers |= UInt32(shiftKey)
            default:
                keyChar = char
            }
        }

        guard let key = keyChar else { return nil }

        // Map common characters to key codes
        let keyCode: UInt32
        switch key.lowercased() {
        case "c": keyCode = 8   // kVK_ANSI_C
        case "v": keyCode = 9   // kVK_ANSI_V
        case "x": keyCode = 7   // kVK_ANSI_X
        case "z": keyCode = 6   // kVK_ANSI_Z
        case "a": keyCode = 0   // kVK_ANSI_A
        case "s": keyCode = 1   // kVK_ANSI_S
        case "d": keyCode = 2   // kVK_ANSI_D
        case "r": keyCode = 15  // kVK_ANSI_R
        case "t": keyCode = 17  // kVK_ANSI_T
        case "m": keyCode = 46  // kVK_ANSI_M
        case " ": keyCode = 49  // kVK_Space
        default: return nil
        }

        return (modifiers, keyCode)
    }
}
#endif
