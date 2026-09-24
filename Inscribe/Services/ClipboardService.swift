import Foundation
import os

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Cross-platform clipboard service for copying transcribed text
enum ClipboardService {

    /// Copy plain text to the system clipboard.
    ///
    /// Written for this Mac only, so a dictation is never offered to the user's other
    /// devices through Universal Clipboard.
    ///
    /// - Parameter transient: Mark the copy as momentary, for a paste that puts the
    ///   user's own clipboard back straight afterwards. Clipboard managers that follow
    ///   the nspasteboard.org conventions then leave it out of their history.
    /// - Returns: The clipboard's change count after the write, so a caller can tell
    ///   whether anything has replaced it since. Always 0 on iOS.
    @discardableResult
    static func copy(_ text: String, transient: Bool = false) -> Int {
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        let change = pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.setString(text, forType: .string)
        if transient {
            pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        }
        #else
        UIPasteboard.general.string = text
        let change = 0
        #endif

        Log.clipboard.notice("Copied \(text.count, privacy: .public) characters to clipboard")
        return change
    }

    #if os(macOS)
    /// Everything on the clipboard: every item, in every type it offers.
    ///
    /// Plain text alone used to be kept, so a copied screenshot was lost to the
    /// dictation, a copied file came back as its name, and rich text lost its styling.
    static func snapshot() -> [NSPasteboardItem] {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    /// Put back what `snapshot()` took.
    static func restore(_ items: [NSPasteboardItem]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }

    /// The clipboard's current change count.
    static var changeCount: Int { NSPasteboard.general.changeCount }
    #endif

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
