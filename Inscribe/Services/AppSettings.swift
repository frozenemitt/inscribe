import Foundation
import SwiftUI

/// Lightweight app settings for the background transcription tool
@Observable
final class AppSettings {

    // MARK: - AI Processing Settings

    /// Whether to process transcription with AI before copying
    var aiEnabled: Bool {
        didSet { save("aiEnabled", aiEnabled) }
    }

    /// The currently selected prompt ID (nil = use default)
    var selectedPromptId: UUID? {
        didSet { save("selectedPromptId", selectedPromptId?.uuidString) }
    }

    // MARK: - Behavior Settings

    /// Whether to automatically copy to clipboard after transcription
    var copyToClipboardAutomatically: Bool {
        didSet { save("copyToClipboardAutomatically", copyToClipboardAutomatically) }
    }

    /// Whether to play feedback sounds on start/stop
    var playFeedbackSounds: Bool {
        didSet { save("playFeedbackSounds", playFeedbackSounds) }
    }

    /// Whether to play a looping sound during AI processing
    var playProcessingIndicator: Bool {
        didSet { save("playProcessingIndicator", playProcessingIndicator) }
    }

    // MARK: - Sound Selection (macOS)

    /// Sound to play when recording starts
    var startSoundName: String {
        didSet { save("startSoundName", startSoundName) }
    }

    /// Sound to play when recording stops
    var stopSoundName: String {
        didSet { save("stopSoundName", stopSoundName) }
    }

    /// Sound to play when processing completes
    var completeSoundName: String {
        didSet { save("completeSoundName", completeSoundName) }
    }

    /// Sound to play on error
    var errorSoundName: String {
        didSet { save("errorSoundName", errorSoundName) }
    }

    /// Sound to loop during AI processing
    var processingSoundName: String {
        didSet { save("processingSoundName", processingSoundName) }
    }

    // MARK: - Transcript Processing

    /// Case-insensitive whole-word substitutions applied to every transcript,
    /// for names and jargon the transcriber reliably mishears.
    var wordReplacements: [String: String] {
        didSet { save("wordReplacements", wordReplacements) }
    }

    /// Terms handed to the recognizer up front so it expects them.
    ///
    /// Unlike replacements, which repair a wrong guess after the fact, these change
    /// what the model is listening for — better for proper nouns it has never seen.
    var vocabularyHints: [String] {
        didSet { save("vocabularyHints", vocabularyHints) }
    }

    // MARK: - Audio Input

    /// CoreAudio UID of the microphone, or "default" to follow the system setting.
    var inputDeviceUID: String {
        didSet { save("inputDeviceUID", inputDeviceUID) }
    }

    /// Record what the Mac is playing alongside the microphone, during meetings.
    ///
    /// Off by default: it needs its own macOS permission, and it records everyone on
    /// the call rather than only the person holding the Mac.
    var captureSystemAudioInMeetings: Bool {
        didSet { save("captureSystemAudioInMeetings", captureSystemAudioInMeetings) }
    }

    /// Keep the recording after a meeting ends.
    ///
    /// On by default: without the audio there is no way to check whether a speaker
    /// correction is right, and no way to re-run diarization after a model update.
    var keepMeetingAudio: Bool {
        didSet { save("keepMeetingAudio", keepMeetingAudio) }
    }

    // MARK: - Dictation History

    /// Keep a scrollback of finished dictations.
    ///
    /// Everything dictated is then stored in plain text on disk. On by default because
    /// losing a dictation to the wrong window is common and otherwise unrecoverable,
    /// but it is the user's call.
    var keepDictationHistory: Bool {
        didSet { save("keepDictationHistory", keepDictationHistory) }
    }

    /// How many dictations to keep before the oldest are dropped.
    var dictationHistoryLimit: Int {
        didSet { save("dictationHistoryLimit", dictationHistoryLimit) }
    }

    // MARK: - Notifications

    /// Notify when a transcript is ready.
    var showNotifications: Bool {
        didSet { save("showNotifications", showNotifications) }
    }

    /// Notify when transcription or the AI pass fails.
    ///
    /// Separate from the success notification: silencing routine "done" banners
    /// should not also silence the ones that explain why nothing appeared.
    var notifyOnError: Bool {
        didSet { save("notifyOnError", notifyOnError) }
    }

    // MARK: - Hotkey Behaviour (macOS only)

    /// How the hotkey drives recording: "pushToTalk" (hold to talk) or
    /// "toggle" (press to start, press again to stop).
    var hotkeyActivationModeRaw: String {
        didSet { save("hotkeyActivationModeRaw", hotkeyActivationModeRaw) }
    }

    /// How solid the dictation panel's glass is. Below about a third the words start
    /// competing with whatever is behind them.
    var overlayOpacity: Double {
        didSet { save("overlayOpacity", overlayOpacity) }
    }

    /// Where the user dragged the dictation panel, if they ever did.
    ///
    /// Absent means the default: bottom centre of whichever screen holds the pointer.
    var overlayOriginX: Double? {
        didSet { save("overlayOriginX", overlayOriginX) }
    }

    var overlayOriginY: Double? {
        didSet { save("overlayOriginY", overlayOriginY) }
    }

    /// Where the user dragged the meeting indicator, if they ever did.
    var meetingIndicatorOriginX: Double? {
        didSet { save("meetingIndicatorOriginX", meetingIndicatorOriginX) }
    }

    var meetingIndicatorOriginY: Double? {
        didSet { save("meetingIndicatorOriginY", meetingIndicatorOriginY) }
    }

    /// Float a small panel showing the microphone while a meeting records.
    var showMeetingIndicator: Bool {
        didSet { save("showMeetingIndicator", showMeetingIndicator) }
    }

    /// Use the Globe / Fn key on its own instead of the key combination below.
    var useGlobeKey: Bool {
        didSet { save("useGlobeKey", useGlobeKey) }
    }

    /// Enable a second shortcut that takes back the last insertion.
    var undoHotkeyEnabled: Bool {
        didSet { save("undoHotkeyEnabled", undoHotkeyEnabled) }
    }

    /// The undo shortcut. Always a combination — the Globe key is taken.
    var undoHotkeyString: String {
        didSet { save("undoHotkeyString", undoHotkeyString) }
    }

    // MARK: - Output Behaviour (macOS only)

    /// Where finished text goes: "smartInsert" types into the focused text field and
    /// falls back to the clipboard, "clipboardOnly" always uses the clipboard.
    var outputModeRaw: String {
        didSet { save("outputModeRaw", outputModeRaw) }
    }

    /// Put the previous clipboard contents back after pasting into a text field.
    var restoreClipboardAfterPaste: Bool {
        didSet { save("restoreClipboardAfterPaste", restoreClipboardAfterPaste) }
    }

    /// Float a panel showing the words as they are heard.
    var showDictationOverlay: Bool {
        didSet { save("showDictationOverlay", showDictationOverlay) }
    }

    /// Show the AI what is already in the field being dictated into.
    ///
    /// Reads the focused field's existing text, so a dictated reply can match the
    /// thread above it. Uses the Accessibility access smart insert already needs.
    var useSurroundingContext: Bool {
        didSet { save("useSurroundingContext", useSurroundingContext) }
    }

    /// Press a Return key after inserting, for chat boxes and search fields.
    var autoSubmitAfterInsert: Bool {
        didSet { save("autoSubmitAfterInsert", autoSubmitAfterInsert) }
    }

    /// Send Shift+Return rather than Return.
    ///
    /// Chat apps read a bare Return as "send". Shift+Return drops to a new line and
    /// leaves the message sitting in the box, which is what you want when dictation
    /// is one paragraph of several.
    var useShiftReturnAfterInsert: Bool {
        didSet { save("useShiftReturnAfterInsert", useShiftReturnAfterInsert) }
    }

    /// Safety cap on a single recording, in seconds.
    var maxRecordingSeconds: Int {
        didSet { save("maxRecordingSeconds", maxRecordingSeconds) }
    }

    // MARK: - Hotkey Settings (macOS only)

    /// The global hotkey combination (stored as string representation)
    var hotkeyString: String {
        didSet { save("hotkeyString", hotkeyString) }
    }

    // MARK: - Initialization

    init() {
        // Load saved settings with defaults
        self.aiEnabled = UserDefaults.standard.object(forKey: "aiEnabled") as? Bool ?? true
        self.copyToClipboardAutomatically = UserDefaults.standard.object(forKey: "copyToClipboardAutomatically") as? Bool ?? true
        self.playFeedbackSounds = UserDefaults.standard.object(forKey: "playFeedbackSounds") as? Bool ?? true
        self.showNotifications = UserDefaults.standard.object(forKey: "showNotifications") as? Bool ?? true
        self.playProcessingIndicator = UserDefaults.standard.object(forKey: "playProcessingIndicator") as? Bool ?? true
        self.startSoundName = UserDefaults.standard.string(forKey: "startSoundName") ?? "Morse"
        self.stopSoundName = UserDefaults.standard.string(forKey: "stopSoundName") ?? "Pop"
        self.completeSoundName = UserDefaults.standard.string(forKey: "completeSoundName") ?? "Glass"
        self.errorSoundName = UserDefaults.standard.string(forKey: "errorSoundName") ?? "Basso"
        self.processingSoundName = UserDefaults.standard.string(forKey: "processingSoundName") ?? "Bottle"
        self.hotkeyString = UserDefaults.standard.string(forKey: "hotkeyString") ?? "⌃⌥⌘C"
        self.hotkeyActivationModeRaw = UserDefaults.standard.string(forKey: "hotkeyActivationModeRaw") ?? "pushToTalk"
        self.useGlobeKey = UserDefaults.standard.object(forKey: "useGlobeKey") as? Bool ?? true
        self.undoHotkeyEnabled = UserDefaults.standard.object(forKey: "undoHotkeyEnabled") as? Bool ?? true
        self.undoHotkeyString = UserDefaults.standard.string(forKey: "undoHotkeyString") ?? "⌃⌥⌘Z"
        self.outputModeRaw = UserDefaults.standard.string(forKey: "outputModeRaw") ?? "smartInsert"
        self.restoreClipboardAfterPaste = UserDefaults.standard.object(forKey: "restoreClipboardAfterPaste") as? Bool ?? true
        self.autoSubmitAfterInsert = UserDefaults.standard.object(forKey: "autoSubmitAfterInsert") as? Bool ?? false
        self.useSurroundingContext = UserDefaults.standard.object(forKey: "useSurroundingContext") as? Bool ?? false
        self.showDictationOverlay = UserDefaults.standard.object(forKey: "showDictationOverlay") as? Bool ?? true
        self.overlayOpacity = UserDefaults.standard.object(forKey: "overlayOpacity") as? Double ?? 0.75
        self.overlayOriginX = UserDefaults.standard.object(forKey: "overlayOriginX") as? Double
        self.overlayOriginY = UserDefaults.standard.object(forKey: "overlayOriginY") as? Double
        self.meetingIndicatorOriginX = UserDefaults.standard.object(forKey: "meetingIndicatorOriginX") as? Double
        self.meetingIndicatorOriginY = UserDefaults.standard.object(forKey: "meetingIndicatorOriginY") as? Double
        self.showMeetingIndicator = UserDefaults.standard.object(forKey: "showMeetingIndicator") as? Bool ?? true
        self.useShiftReturnAfterInsert = UserDefaults.standard.object(forKey: "useShiftReturnAfterInsert") as? Bool ?? false
        self.maxRecordingSeconds = UserDefaults.standard.object(forKey: "maxRecordingSeconds") as? Int ?? 600
        self.wordReplacements = UserDefaults.standard.dictionary(forKey: "wordReplacements") as? [String: String] ?? [:]
        self.vocabularyHints = UserDefaults.standard.stringArray(forKey: "vocabularyHints") ?? []
        self.inputDeviceUID = UserDefaults.standard.string(forKey: "inputDeviceUID") ?? "default"
        self.captureSystemAudioInMeetings = UserDefaults.standard.object(forKey: "captureSystemAudioInMeetings") as? Bool ?? false
        self.keepMeetingAudio = UserDefaults.standard.object(forKey: "keepMeetingAudio") as? Bool ?? true
        self.keepDictationHistory = UserDefaults.standard.object(forKey: "keepDictationHistory") as? Bool ?? true
        self.dictationHistoryLimit = UserDefaults.standard.object(forKey: "dictationHistoryLimit") as? Int ?? 100
        self.notifyOnError = UserDefaults.standard.object(forKey: "notifyOnError") as? Bool ?? true
        self.appProfilesData = UserDefaults.standard.data(forKey: "appProfilesData")

        // Load optional values
        if let promptIdString = UserDefaults.standard.string(forKey: "selectedPromptId") {
            self.selectedPromptId = UUID(uuidString: promptIdString)
        } else {
            self.selectedPromptId = nil
        }

        print("[AppSettings] Loaded settings - AI: \(aiEnabled), Clipboard: \(copyToClipboardAutomatically)")
    }

    // MARK: - Per-App Profiles

    /// JSON backing store. Use `appProfiles` rather than touching this.
    var appProfilesData: Data? {
        didSet { save("appProfilesData", appProfilesData) }
    }

    /// Per-app overrides, keyed by bundle identifier.
    ///
    /// Dictation into a terminal wants different treatment from dictation into a
    /// document, and the app you are typing into is the only reliable signal for which
    /// is which.
    var appProfiles: [String: AppProfile] {
        get {
            guard let appProfilesData,
                  let decoded = try? JSONDecoder().decode([String: AppProfile].self, from: appProfilesData) else {
                return [:]
            }
            return decoded
        }
        set {
            appProfilesData = try? JSONEncoder().encode(newValue)
        }
    }

    /// The profile for a bundle identifier, if one is set and switched on.
    func profile(forBundleIdentifier bundleID: String?) -> AppProfile? {
        guard let bundleID, let profile = appProfiles[bundleID], profile.isEnabled else { return nil }
        return profile
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
    func resetToDefaults() {
        aiEnabled = true
        selectedPromptId = nil
        copyToClipboardAutomatically = true
        playFeedbackSounds = true
        showNotifications = true
        playProcessingIndicator = true
        startSoundName = "Morse"
        stopSoundName = "Pop"
        completeSoundName = "Glass"
        errorSoundName = "Basso"
        processingSoundName = "Bottle"
        hotkeyString = "⌃⌥⌘C"
        hotkeyActivationModeRaw = "pushToTalk"
        useGlobeKey = true
        undoHotkeyEnabled = true
        undoHotkeyString = "⌃⌥⌘Z"
        outputModeRaw = "smartInsert"
        restoreClipboardAfterPaste = true
        autoSubmitAfterInsert = false
        useSurroundingContext = false
        showDictationOverlay = true
        overlayOpacity = 0.75
        overlayOriginX = nil
        overlayOriginY = nil
        meetingIndicatorOriginX = nil
        meetingIndicatorOriginY = nil
        showMeetingIndicator = true
        useShiftReturnAfterInsert = false
        maxRecordingSeconds = 600
        wordReplacements = [:]
        vocabularyHints = []
        inputDeviceUID = "default"
        captureSystemAudioInMeetings = false
        keepMeetingAudio = true
        keepDictationHistory = true
        dictationHistoryLimit = 100
        notifyOnError = true
        appProfilesData = nil

        print("[AppSettings] Reset to defaults")
    }

    /// Check if AI processing should be used for current transcription
    var shouldProcessWithAI: Bool {
        aiEnabled && selectedPromptId != nil
    }

    /// Get the user's chosen sound ID for a feedback sound event
    func soundId(for sound: AudioFeedbackService.Sound) -> String {
        switch sound {
        case .recordingStarted: return startSoundName
        case .recordingStopped: return stopSoundName
        case .processingComplete: return completeSoundName
        case .error: return errorSoundName
        }
    }
}

// MARK: - Output Mode

/// Where finished text goes.
enum OutputMode: String, CaseIterable, Identifiable, Sendable {
    /// Type into the focused text field; fall back to the clipboard when there isn't one.
    case smartInsert
    /// Always copy, never type.
    case clipboardOnly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .smartInsert: "Type into the focused field, otherwise copy"
        case .clipboardOnly: "Always copy to the clipboard"
        }
    }
}

// MARK: - Typed Accessors (macOS)

#if os(macOS)
import CoreGraphics

extension AppSettings {

    /// Hold-to-talk or press-to-toggle, backed by `hotkeyActivationModeRaw`.
    var hotkeyActivationMode: HotkeyActivationMode {
        get { HotkeyActivationMode(rawValue: hotkeyActivationModeRaw) ?? .pushToTalk }
        set { hotkeyActivationModeRaw = newValue.rawValue }
    }

    /// Insert-or-copy behaviour, backed by `outputModeRaw`.
    var outputMode: OutputMode {
        get { OutputMode(rawValue: outputModeRaw) ?? .smartInsert }
        set { outputModeRaw = newValue.rawValue }
    }

    /// The trigger to hand `GlobalHotkeyMonitor`.
    ///
    /// Falls back to the Globe key when `hotkeyString` cannot be parsed, so a bad
    /// custom combination leaves the user with a working hotkey rather than none.
    var hotkeyTrigger: HotkeyTrigger {
        guard !useGlobeKey else { return .globe }
        guard let (keyCode, flags) = parseHotkeyForEventTap() else {
            print("[AppSettings] Could not parse '\(hotkeyString)', falling back to the Globe key")
            return .globe
        }
        return .combo(keyCode: keyCode, modifiers: flags)
    }

    /// The undo binding to hand `GlobalHotkeyMonitor`, if enabled and parseable.
    var undoHotkeyTrigger: HotkeyTrigger? {
        guard undoHotkeyEnabled,
              let (keyCode, flags) = parseHotkeyForEventTap(undoHotkeyString) else { return nil }
        return .combo(keyCode: keyCode, modifiers: flags)
    }

    /// Parse `hotkeyString` (e.g. "⌃⌥⌘C") into event-tap terms.
    func parseHotkeyForEventTap() -> (keyCode: CGKeyCode, modifiers: CGEventFlags)? {
        parseHotkeyForEventTap(hotkeyString)
    }

    func parseHotkeyForEventTap(_ string: String) -> (keyCode: CGKeyCode, modifiers: CGEventFlags)? {
        var flags: CGEventFlags = []
        var keyChar: Character?

        for char in string {
            switch char {
            case "⌃": flags.insert(.maskControl)
            case "⌥": flags.insert(.maskAlternate)
            case "⌘": flags.insert(.maskCommand)
            case "⇧": flags.insert(.maskShift)
            default: keyChar = char
            }
        }

        guard let key = keyChar, let keyCode = Self.keyCode(for: key) else { return nil }
        return (keyCode, flags)
    }

    /// US-layout virtual key codes for the characters a hotkey may use.
    private static let keyCodes: [Character: CGKeyCode] = [
        "a": 0,  "s": 1,  "d": 2,  "f": 3,  "h": 4,  "g": 5,  "z": 6,  "x": 7,
        "c": 8,  "v": 9,  "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16,
        "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24,
        "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32,
        "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41,
        "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, " ": 49
    ]

    private static func keyCode(for character: Character) -> CGKeyCode? {
        guard let lowered = character.lowercased().first else { return nil }
        return keyCodes[lowered]
    }

    /// Write a captured keystroke the way `hotkeyString` stores it, e.g. "⌃⌥⌘C".
    ///
    /// Nil when the keystroke cannot be a trigger: a key outside the table above, or
    /// one pressed without ⌃, ⌥ or ⌘, which would swallow that plain keystroke in
    /// every app on the machine.
    static func hotkeyString(forKeyCode keyCode: CGKeyCode, modifiers: CGEventFlags) -> String? {
        let control = modifiers.contains(.maskControl)
        let option = modifiers.contains(.maskAlternate)
        let command = modifiers.contains(.maskCommand)

        // Two of them, not one. The tap swallows the trigger in every app on the
        // machine, so a single-modifier binding takes that keystroke away everywhere:
        // record ⌘W to dismiss the settings window and ⌘W stops closing windows.
        let count = [control, option, command].filter { $0 }.count
        guard count >= 2 else { return nil }

        guard let character = keyCodes.first(where: { $0.value == keyCode })?.key else { return nil }

        var parts = ""
        if control { parts += "⌃" }
        if option { parts += "⌥" }
        if modifiers.contains(.maskShift) { parts += "⇧" }
        if command { parts += "⌘" }
        return parts + String(character).uppercased()
    }
}
#endif

// MARK: - Per-App Profile

/// Settings that override the global ones while a particular app is frontmost.
struct AppProfile: Codable, Hashable, Identifiable, Sendable {
    /// Bundle identifier of the app this applies to, e.g. "com.tinyspeck.slackmacgap".
    var bundleIdentifier: String

    /// Display name, kept so the settings list stays readable when the app is not running.
    var appName: String

    /// Prompt to use instead of the default. Nil leaves the global choice alone.
    var promptId: UUID?

    /// Output mode to use instead of the default. Nil leaves the global choice alone.
    var outputModeRaw: String?

    /// Press Return after inserting. Nil leaves the global choice alone.
    var autoSubmit: Bool?

    /// Turned off without deleting, so a profile can be parked rather than rebuilt.
    var isEnabled: Bool = true

    var id: String { bundleIdentifier }
}
