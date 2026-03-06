import Foundation

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Cross-platform clipboard service for copying transcribed text
enum ClipboardService {

    /// Copy plain text to the system clipboard
    static func copy(_ text: String) {
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif

        print("[ClipboardService] Copied \(text.count) characters to clipboard")
    }

    /// Copy text and return success status
    @discardableResult
    static func copyWithResult(_ text: String) -> Bool {
        guard !text.isEmpty else {
            print("[ClipboardService] Failed to copy: text is empty")
            return false
        }

        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let success = pasteboard.setString(text, forType: .string)
        print("[ClipboardService] Copy result: \(success)")
        return success
        #else
        UIPasteboard.general.string = text
        print("[ClipboardService] Copied \(text.count) characters to clipboard")
        return true
        #endif
    }

    /// Read current clipboard contents (useful for testing)
    static func read() -> String? {
        #if os(macOS)
        return NSPasteboard.general.string(forType: .string)
        #else
        return UIPasteboard.general.string
        #endif
    }

    /// Check if clipboard has text content
    static func hasText() -> Bool {
        #if os(macOS)
        return NSPasteboard.general.string(forType: .string) != nil
        #else
        return UIPasteboard.general.hasStrings
        #endif
    }

    /// Clear the clipboard
    static func clear() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        #else
        UIPasteboard.general.string = ""
        #endif
    }
}
