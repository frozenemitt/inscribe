import Foundation
import Observation

#if os(macOS)
import Carbon
import AppKit

/// Global hotkey service for macOS
/// Registers and handles system-wide keyboard shortcuts
@MainActor
@Observable
final class HotkeyService {

    // MARK: - Published State

    private(set) var isRegistered = false
    private(set) var lastError: String?

    // MARK: - Hotkey Configuration

    private var eventHandler: EventHandlerRef?
    private var hotkeyRef: EventHotKeyRef?
    private var hotkeyId: EventHotKeyID

    /// Callback when hotkey is pressed
    var onHotkeyPressed: (() -> Void)?

    // MARK: - Singleton for Carbon callback

    fileprivate static var shared: HotkeyService?

    // MARK: - Initialization

    init() {
        self.hotkeyId = EventHotKeyID(signature: OSType("INSC".fourCharCode), id: 1)
        HotkeyService.shared = self
    }

    deinit {
        MainActor.assumeIsolated {
            if let hotkeyRef = hotkeyRef {
                UnregisterEventHotKey(hotkeyRef)
            }
        }
    }

    // MARK: - Public API

    /// Register a global hotkey
    /// - Parameters:
    ///   - modifiers: Modifier flags (control, option, command, shift)
    ///   - keyCode: The key code
    func registerHotkey(modifiers: UInt32, keyCode: UInt32) {
        // Unregister existing hotkey first
        unregisterHotkey()

        // Install event handler if not already installed
        if eventHandler == nil {
            var eventSpec = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )

            let status = InstallEventHandler(
                GetApplicationEventTarget(),
                hotkeyCallback,
                1,
                &eventSpec,
                nil,
                &eventHandler
            )

            if status != noErr {
                lastError = "Failed to install event handler: \(status)"
                print("[HotkeyService] \(lastError!)")
                return
            }
        }

        // Register the hotkey
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotkeyId,
            GetApplicationEventTarget(),
            0,
            &hotkeyRef
        )

        if status == noErr {
            isRegistered = true
            lastError = nil
            print("[HotkeyService] Hotkey registered: modifiers=\(modifiers), keyCode=\(keyCode)")
        } else {
            isRegistered = false
            lastError = "Failed to register hotkey: \(status)"
            print("[HotkeyService] \(lastError!)")
        }
    }

    /// Register hotkey from settings string (e.g., "⌃⌥⌘C")
    func registerHotkey(from hotkeyString: String) {
        guard let (modifiers, keyCode) = parseHotkeyString(hotkeyString) else {
            lastError = "Invalid hotkey string: \(hotkeyString)"
            print("[HotkeyService] \(lastError!)")
            return
        }

        registerHotkey(modifiers: modifiers, keyCode: keyCode)
    }

    /// Unregister the current hotkey
    func unregisterHotkey() {
        if let hotkeyRef = hotkeyRef {
            UnregisterEventHotKey(hotkeyRef)
            self.hotkeyRef = nil
            isRegistered = false
            print("[HotkeyService] Hotkey unregistered")
        }
    }

    // MARK: - Hotkey Parsing

    private func parseHotkeyString(_ string: String) -> (modifiers: UInt32, keyCode: UInt32)? {
        var modifiers: UInt32 = 0
        var keyChar: Character?

        for char in string {
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
                if char.isLetter || char == " " {
                    keyChar = char
                }
            }
        }

        guard let key = keyChar else {
            return nil
        }

        // Map character to key code
        guard let keyCode = keyCodeForCharacter(key) else {
            return nil
        }

        return (modifiers, keyCode)
    }

    private func keyCodeForCharacter(_ char: Character) -> UInt32? {
        let keyMap: [Character: UInt32] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
            "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
            "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
            "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
            "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37,
            "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
            "n": 45, "m": 46, ".": 47, " ": 49
        ]

        return keyMap[Character(char.lowercased())]
    }

    // MARK: - Callback Handling

    fileprivate func handleHotkeyPressed() {
        print("[HotkeyService] Hotkey pressed!")
        onHotkeyPressed?()
    }
}

// MARK: - Carbon Callback

private func hotkeyCallback(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    Task { @MainActor in
        HotkeyService.shared?.handleHotkeyPressed()
    }
    return noErr
}

// MARK: - String Extension for FourCharCode

private extension String {
    var fourCharCode: UInt32 {
        var result: UInt32 = 0
        for char in self.utf8.prefix(4) {
            result = result << 8 + UInt32(char)
        }
        return result
    }
}

#endif
