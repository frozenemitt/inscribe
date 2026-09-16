import Foundation
import os

/// Where the app says what it is doing.
///
/// Everything used to go through `print`, which reaches nobody once the app is
/// launched from the Dock rather than from Xcode — so an app misbehaving on a real
/// machine left no trace at all. One evening was spent discovering that the hotkey was
/// reporting itself installed while its tap was dead, and the line that said so had
/// been printed into nothing.
///
/// Read it back with:
/// `log show --last 10m --predicate 'subsystem == "com.inscribe.app"' --style compact`
///
/// Levels follow the system's meaning: `notice` is kept on disk and is for things worth
/// finding later, `debug` is for detail you only want while watching live, `error` is
/// for something that went wrong.
///
/// Nothing dictated or transcribed is ever written here. Counts and states are public
/// so they survive into the log; anything the user wrote — a prompt's name, their own
/// words — is left private, which means the system redacts it.
enum Log {
    private static func make(_ category: String) -> Logger {
        Logger(subsystem: "com.inscribe.app", category: category)
    }

    static let app = make("App")
    static let settings = make("Settings")
    static let dictation = make("Dictation")
    static let audio = make("Audio")
    static let hotkey = make("Hotkey")
    static let ai = make("AI")
    static let prompts = make("Prompts")
    static let meetings = make("Meetings")
    static let diarization = make("Diarization")
    static let intents = make("Intents")
    static let clipboard = make("Clipboard")
    static let notifications = make("Notifications")
    static let liveActivity = make("LiveActivity")
}
