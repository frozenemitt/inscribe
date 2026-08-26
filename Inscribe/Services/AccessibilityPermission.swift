import Foundation

#if os(macOS)
import ApplicationServices
import AppKit

/// Accessibility (AX) trust check.
///
/// Two features depend on it: the Globe-key event tap needs to observe keystrokes
/// system-wide, and text insertion needs to read the focused element and post
/// synthetic keystrokes to another app. macOS grants AX trust only to unsandboxed
/// processes, which is why the macOS target sets ENABLE_APP_SANDBOX = NO.
enum AccessibilityPermission {

    /// Whether this process is currently trusted, without showing a prompt.
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Check trust and ask macOS to show the "grant access" prompt when missing.
    ///
    /// macOS shows the prompt at most once per app version per user; afterwards the
    /// call silently returns false and the user has to grant access by hand.
    @discardableResult
    static func requestTrust() -> Bool {
        // Spelled out rather than read from kAXTrustedCheckOptionPrompt: that global is a
        // mutable CFString under Swift 6 and cannot be touched from a concurrent context.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Open the Accessibility pane of System Settings for the user to grant access by hand.
    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
#endif
