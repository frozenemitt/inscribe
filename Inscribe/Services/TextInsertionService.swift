import Foundation
import os

#if os(macOS)
import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Where the transcribed text ended up.
enum TextInsertionOutcome: Sendable, Equatable {
    /// Typed into the text field that had focus, naming the app that received it.
    case inserted(appName: String)
    /// No text field had focus, so the text went to the clipboard instead.
    case copiedToClipboard(reason: ClipboardReason)

    enum ClipboardReason: Sendable, Equatable {
        case noFocusedTextField
        case accessibilityNotTrusted
        case insertionFailed
        case userPreference
    }
}

/// Writes transcribed text into whatever text field currently has focus, falling
/// back to the clipboard when there isn't one.
///
/// Insertion goes through the pasteboard and a synthetic ⌘V rather than
/// `AXUIElementSetAttributeValue`. Setting the AX value works in native AppKit
/// controls but silently does nothing in Electron apps and browser text fields,
/// which is where most dictation actually lands.
@MainActor
enum TextInsertionService {

    /// Diagnostics go to the unified log, not stdout: launched from Finder there is
    /// no stdout to read. Follow with:
    ///   log stream --predicate 'subsystem == "com.inscribe.app"' --level debug
    private static let log = Logger(subsystem: "com.inscribe.app", category: "TextInsertion")

    /// What the last insertion did, so it can be undone.
    ///
    /// Undo sends the receiving app its own ⌘Z rather than trying to delete the
    /// characters. The app knows what its undo means; guessing by selecting backwards
    /// breaks the moment autocorrect, an editor macro, or a text replacement has
    /// changed what actually landed.
    struct LastInsertion: Sendable {
        let text: String
        let appName: String
        let processIdentifier: pid_t
        let at: Date
    }

    private(set) static var lastInsertion: LastInsertion?

    /// Whether there is something recent enough to be worth undoing.
    ///
    /// Time-limited: an undo fired ten minutes later would send ⌘Z into whatever the
    /// user has been doing since, throwing away unrelated work.
    static var canUndo: Bool {
        guard let lastInsertion else { return false }
        return Date().timeIntervalSince(lastInsertion.at) < 120
    }

    /// Take back the last insertion and put its text back on the clipboard.
    @discardableResult
    static func undoLastInsertion() async -> String? {
        guard let last = lastInsertion, canUndo else { return nil }
        guard AccessibilityPermission.isTrusted else { return nil }

        // Only undo in the app that received the text. Sending ⌘Z to whatever happens
        // to be frontmost now would destroy something unrelated.
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.processIdentifier != last.processIdentifier {
            guard let target = NSRunningApplication(processIdentifier: last.processIdentifier),
                  !target.isTerminated else {
                log.notice("The app that received the text is gone; not undoing")
                return nil
            }
            target.activate()
            try? await Task.sleep(for: .milliseconds(200))

            // ⌘Z goes to whatever is in front. If macOS refused the activation, it
            // would undo the user's last edit in some other app.
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == last.processIdentifier else {
                log.notice("\(last.appName, privacy: .public) did not come to the front; not undoing")
                return nil
            }
        }

        await waitForModifiersToClear()
        _ = postKeystroke(keyCode: CGKeyCode(kVK_ANSI_Z), flags: .maskCommand)

        // The words are not lost, just taken out of the document.
        ClipboardService.copy(last.text)
        lastInsertion = nil

        log.notice("Undid insertion into \(last.appName, privacy: .public)")
        return last.text
    }

    /// Roles that accept typed text.
    private static let textRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
        "AXSearchField"
    ]

    // MARK: - Public API

    /// Ask `app` to build an accessibility tree, before we need to read it.
    ///
    /// Chromium-based apps — Electron ones like Claude, Slack, VS Code, Cursor,
    /// Discord — ship with their accessibility tree switched off and build it lazily
    /// only once a client asks. Until then `kAXFocusedUIElement` answers
    /// `kAXErrorNoValue` however many text fields are on screen, so focus detection
    /// cannot work. `AXManualAccessibility` is Chromium's opt-in for exactly this.
    ///
    /// Called at the start of recording rather than at delivery, so the tree is built
    /// while the user is still talking instead of costing them latency afterwards.
    /// Non-Chromium apps reject the attribute harmlessly.
    static func prepareForInsertion(into app: NSRunningApplication?) {
        guard let app, !app.isTerminated, AccessibilityPermission.isTrusted else { return }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        // A hint, not a requirement, so it is not worth waiting long for.
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        let status = AXUIElementSetAttributeValue(
            appElement,
            "AXManualAccessibility" as CFString,
            kCFBooleanTrue
        )
        log.debug("""
            AXManualAccessibility on \(app.localizedName ?? "?", privacy: .public) \
            -> AXError \(status.rawValue)
            """)
    }


    /// Cap how long any accessibility request may wait for an app to answer.
    ///
    /// Set on the system-wide element, which makes it the default for every element.
    /// The system's own default is several seconds, and every one of those calls runs
    /// on the main thread, so a hung app froze Inscribe with it. A second is ample for
    /// a healthy app, including a Chromium one building its tree; the focus lookup
    /// retries on its own.
    static func limitAccessibilityWaits() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)
    }

    /// Deliver `text` to the frontmost app, or to the clipboard if no field is focused.
    ///
    /// - Parameters:
    ///   - text: The transcribed text.
    ///   - targetApp: The app that was frontmost when recording began. Both the
    ///     re-activation target and the app we ask about focus.
    ///   - restoreClipboard: Put the previous clipboard contents back after pasting.
    ///   - autoSubmit: Press a Return key after inserting.
    ///   - submitUsesShift: Send Shift+Return instead of Return, so chat apps add a
    ///     line break rather than sending the message.
    ///   - addSpace: Paste a space after the text, so the next words carry on from it.
    @discardableResult
    static func deliver(
        _ text: String,
        targetApp: NSRunningApplication? = nil,
        restoreClipboard: Bool = true,
        autoSubmit: Bool = false,
        submitUsesShift: Bool = false,
        addSpace: Bool = false
    ) async -> TextInsertionOutcome {

        guard !text.isEmpty else {
            return .copiedToClipboard(reason: .insertionFailed)
        }

        guard AccessibilityPermission.isTrusted else {
            log.error("Not trusted for Accessibility — clipboard only")
            ClipboardService.copy(text)
            return .copiedToClipboard(reason: .accessibilityNotTrusted)
        }

        await restoreFocusIfNeeded(to: targetApp)

        // Nothing was typed into an app, so there is nothing for ⌘Z to take back.
        lastInsertion = nil

        guard let field = await awaitFocusedTextElement(in: targetApp) else {
            log.notice("""
                No focused text field in \(targetApp?.localizedName ?? "target", privacy: .public) \
                — falling back to clipboard
                """)
            ClipboardService.copy(text)
            return .copiedToClipboard(reason: .noFocusedTextField)
        }

        let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "the frontmost app"
        log.debug("Inserting \(text.count) chars into \(appName, privacy: .public)")

        // Physical modifiers from the hotkey may still be down; a ⌘V posted now
        // would arrive as ⌃⌥⌘V. Wait for the user's hand to leave the keys.
        await waitForModifiersToClear()

        // The field was found by asking the target app, but ⌘V goes to whatever app is
        // in front. macOS can refuse the activation above, and the text then landed in
        // the app the user had moved on to — a Mail draft instead of a Slack reply.
        if let targetApp, NSWorkspace.shared.frontmostApplication?.processIdentifier != targetApp.processIdentifier {
            log.error("""
                \(targetApp.localizedName ?? "The target app", privacy: .public) is not in front \
                — leaving the transcript on the clipboard instead of pasting into \
                \(appName, privacy: .public)
                """)
            ClipboardService.copy(text)
            return .copiedToClipboard(reason: .insertionFailed)
        }

        let previousClipboard = restoreClipboard ? ClipboardService.snapshot() : nil

        // Read before pasting, so the field can be compared against itself afterwards.
        let fieldBeforePaste = state(of: field)

        // Marked as momentary when the user's clipboard goes back afterwards, so
        // clipboard managers do not keep every dictation.
        let pasteChange = ClipboardService.copy(addSpace ? text + " " : text, transient: restoreClipboard)

        // Give the pasteboard a moment to settle before the receiving app reads it.
        try? await Task.sleep(for: .milliseconds(50))

        guard postPasteKeystroke() else {
            log.error("Could not post ⌘V — text left on the clipboard")
            return .copiedToClipboard(reason: .insertionFailed)
        }

        guard await pasteLanded(in: field, changedFrom: fieldBeforePaste) else {
            // The read-back says the field never moved, which has two very different
            // causes and the same appearance: the paste really did not land, or it
            // landed and this element did not report it — Electron fields update their
            // accessibility value late, or not at all.
            //
            // Lengths and a yes-or-no, never the text itself. Whether the transcript is
            // now in the field is the whole question, and it decides whether a fix
            // belongs in the pasting or in the checking.
            let after = state(of: field)
            let landed = after.text?.contains(text) ?? false
            log.error("""
                ⌘V did nothing in \(appName, privacy: .public) \
                — leaving the transcript on the clipboard. \
                field was \(fieldBeforePaste.text?.count ?? -1, privacy: .public) chars, \
                now \(after.text?.count ?? -1, privacy: .public); \
                caret \(fieldBeforePaste.caret ?? -1, privacy: .public) → \
                \(after.caret ?? -1, privacy: .public); \
                transcript present: \(landed, privacy: .public)
                """)
            return .copiedToClipboard(reason: .insertionFailed)
        }

        if autoSubmit {
            postReturnKeystroke(withShift: submitUsesShift)
            log.debug("Pressed \(submitUsesShift ? "Shift+Return" : "Return", privacy: .public)")
        }

        if let previousClipboard {
            // Safe to put back now: the text is in the field, so the app has already
            // read the pasteboard. Not if something replaced the transcript meanwhile:
            // a copy the user made during the paste is theirs to keep.
            if ClipboardService.changeCount == pasteChange {
                ClipboardService.restore(previousClipboard)
                log.debug("Restored previous clipboard")
            } else {
                log.notice("Clipboard changed during the paste; not restoring the old one")
            }
        }

        if let app = NSWorkspace.shared.frontmostApplication {
            lastInsertion = LastInsertion(
                text: text,
                appName: appName,
                processIdentifier: app.processIdentifier,
                at: Date()
            )
        }

        log.notice("Inserted into \(appName, privacy: .public)")
        return .inserted(appName: appName)
    }

    /// The two things about a text field that a paste always changes.
    ///
    /// Both are read, because apps differ over which one they publish: native controls
    /// give their text as the value, while Electron and browser fields present a
    /// selection range instead.
    private struct FieldState: Equatable {
        var text: String?
        var caret: Int?
    }

    private static func state(of field: AXUIElement) -> FieldState {
        FieldState(
            text: copyAttribute(field, kAXValueAttribute as String) as? String,
            caret: caretLocation(of: field)
        )
    }

    private static func caretLocation(of field: AXUIElement) -> Int? {
        guard let raw = copyAttribute(field, kAXSelectedTextRangeAttribute as String),
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }

        var range = CFRange()
        guard AXValueGetValue(raw as! AXValue, .cfRange, &range) else { return nil }
        return range.location
    }

    /// Whether the ⌘V actually put the text into `field`.
    ///
    /// An element can advertise a text range, accept the keystroke, and do nothing
    /// with it — a web page and a read-only document both look like a text field from
    /// the outside. Reading the field back is the only honest answer, and it has to be
    /// asked before the clipboard is restored: otherwise the previous contents go back
    /// over a transcript that never landed anywhere, and the words are gone.
    ///
    /// Polled rather than slept through once, because apps apply a paste anywhere
    /// between immediately and a couple of hundred milliseconds later.
    ///
    /// A field that changes in neither way counts as a failure. Being wrong there
    /// costs one clipboard left unrestored; being wrong the other way costs the user
    /// their dictation.
    private static func pasteLanded(in field: AXUIElement, changedFrom before: FieldState) async -> Bool {
        // Generous, because waiting costs nothing here: the transcript is on the
        // clipboard for the whole of it, and the loop returns the instant the field
        // moves. A busy Electron field can take most of a second, and calling that a
        // failure loses the user their clipboard and their undo.
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(30))
            if state(of: field) != before { return true }
        }
        return false
    }

    // MARK: - Focus Inspection

    /// Look for a focused text field, retrying briefly.
    ///
    /// A Chromium app told to build its tree for the first time needs a moment. After
    /// the first dictation into a given app the tree stays up and the first try hits.
    private static func awaitFocusedTextElement(in app: NSRunningApplication?) async -> AXUIElement? {
        // Harmless if start-of-recording already did it, and covers an app that was
        // launched or reactivated mid-recording.
        prepareForInsertion(into: app)

        for attempt in 0..<8 {
            if let element = focusedTextElement(in: app) {
                if attempt > 0 {
                    log.debug("Focused element appeared on attempt \(attempt + 1)")
                }
                return element
            }
            try? await Task.sleep(for: .milliseconds(60))
        }
        return nil
    }


    /// The focused element, when it is something that accepts typed text.
    ///
    /// Asks the target app by pid first. The system-wide element resolves against
    /// whatever happens to be frontmost at this instant, which after a menu bar
    /// interaction can be Inscribe itself rather than the app being dictated into.
    static func focusedTextElement(in app: NSRunningApplication? = nil) -> AXUIElement? {
        if let app, !app.isTerminated {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            if let element = copyFocusedElement(of: appElement) {
                if accepts(element, source: "pid \(app.processIdentifier)") { return element }
            } else {
                log.debug("No focused element from pid \(app.processIdentifier)")
            }
        }

        let systemWide = AXUIElementCreateSystemWide()
        if let element = copyFocusedElement(of: systemWide) {
            if accepts(element, source: "system-wide") { return element }
        } else {
            log.debug("No focused element from the system-wide element")
        }

        return nil
    }

    /// What the focused field already contains, for the AI to write into.
    ///
    /// Dictating a reply reads very differently when the model can see the thread above
    /// it. The same Accessibility access that lets Inscribe type into a field lets it
    /// read one, so this costs no new permission.
    ///
    /// - Parameter limit: Characters to keep: the ones just before the cursor, which
    ///   are the words the dictation follows. The end of the field used to be taken,
    ///   so dictating near the top of a long document gave the model its last page.
    static func focusedFieldContext(in app: NSRunningApplication? = nil, limit: Int = 2000) -> String? {
        guard AccessibilityPermission.isTrusted else { return nil }
        guard let element = focusedTextElement(in: app) else { return nil }

        guard let value = copyAttribute(element, kAXValueAttribute as String) as? String else {
            return nil
        }

        // Accessibility reports the cursor in UTF-16 units, as NSString counts them.
        var beforeCursor = value
        let length = (value as NSString).length
        if let caret = caretLocation(of: element), caret >= 0, caret <= length {
            beforeCursor = (value as NSString).substring(to: caret)
        }

        let trimmed = beforeCursor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard trimmed.count > limit else { return trimmed }
        return "…" + String(trimmed.suffix(limit))
    }

    private static func copyFocusedElement(of parent: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            parent,
            kAXFocusedUIElementAttribute as CFString,
            &value
        )
        guard status == .success, let value else {
            if status != .success {
                log.debug("kAXFocusedUIElement failed with AXError \(status.rawValue)")
            }
            return nil
        }
        return (value as! AXUIElement)
    }

    /// Log-annotated wrapper around `acceptsText`, so a rejection says which role lost.
    private static func accepts(_ element: AXUIElement, source: String) -> Bool {
        let role = (copyAttribute(element, kAXRoleAttribute as String) as? String) ?? "unknown"
        let ok = acceptsText(element)
        if ok {
            log.debug("Focused element via \(source, privacy: .public) role=\(role, privacy: .public) accepts text")
        } else {
            log.notice("Focused element via \(source, privacy: .public) role=\(role, privacy: .public) rejected")
        }
        return ok
    }

    /// Three independent signals, because no single one covers every toolkit.
    private static func acceptsText(_ element: AXUIElement) -> Bool {
        // 1. A role that is unambiguously a text control.
        if let role = copyAttribute(element, kAXRoleAttribute as String) as? String,
           textRoles.contains(role) {
            return true
        }

        // 2. A settable value — covers custom controls with unusual roles.
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return true
        }

        // 3. A selected-text range — how Electron and web contenteditable fields present.
        if copyAttribute(element, kAXSelectedTextRangeAttribute as String) != nil {
            return true
        }

        return false
    }

    private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return status == .success ? value : nil
    }

    // MARK: - Focus Restoration

    /// Bring `targetApp` back to the front if something else stole focus mid-recording.
    private static func restoreFocusIfNeeded(to targetApp: NSRunningApplication?) async {
        guard let targetApp, !targetApp.isTerminated else { return }

        let frontmost = NSWorkspace.shared.frontmostApplication
        guard frontmost?.processIdentifier != targetApp.processIdentifier else { return }

        log.debug("""
            Focus moved to \(frontmost?.localizedName ?? "nothing", privacy: .public), \
            reactivating \(targetApp.localizedName ?? "target", privacy: .public)
            """)
        targetApp.activate()
        // Activation is asynchronous; the focused element is stale until it lands.
        try? await Task.sleep(for: .milliseconds(200))
    }

    // MARK: - Synthetic Keystrokes

    /// Wait up to ~500ms for the user to release the hotkey's modifier keys.
    private static func waitForModifiersToClear() async {
        let interesting: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .function]

        for _ in 0..<25 {
            if NSEvent.modifierFlags.intersection(interesting).isEmpty { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        log.debug("Modifiers still held after 500ms, pasting anyway")
    }

    @discardableResult
    private static func postPasteKeystroke() -> Bool {
        postKeystroke(keyCode: CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
    }

    @discardableResult
    private static func postReturnKeystroke(withShift: Bool) -> Bool {
        postKeystroke(keyCode: CGKeyCode(kVK_Return), flags: withShift ? .maskShift : [])
    }

    private static func postKeystroke(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            log.error("Could not create a CGEventSource")
            return false
        }

        // Stop the user's own held keys from merging into the synthetic event.
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            log.error("Could not build the key events")
            return false
        }

        keyDown.flags = flags
        keyUp.flags = flags

        // .cghidEventTap injects at the bottom of the stack, so the event travels the
        // same path as real hardware. .cgAnnotatedSessionEventTap enters further up and
        // some apps never see it.
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}
#endif
