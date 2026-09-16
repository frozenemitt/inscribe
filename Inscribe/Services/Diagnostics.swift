import Foundation
import OSLog

/// Reads back what the app has said about itself since it launched.
///
/// Every part of the app writes to the unified log now, which makes it findable — but
/// only by someone willing to type a `log show` incantation into a terminal. This puts
/// the same lines in front of the user, so a dictation that went wrong can be
/// explained without leaving the app.
///
/// Scoped to this process, so it holds only the current run and reads nothing about
/// any other application. Anything marked private in the log — a prompt's name, a
/// meeting's title — arrives here redacted by the system, exactly as it would in
/// Console.
@MainActor
enum Diagnostics {

    struct Entry: Identifiable {
        let id = UUID()
        let date: Date
        let category: String
        let level: OSLogEntryLog.Level
        let message: String

        var isProblem: Bool { level == .error || level == .fault }
    }

    /// The most recent entries, newest last.
    static func recent(limit: Int = 200) throws -> [Entry] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let start = store.position(date: Date().addingTimeInterval(-60 * 60))

        let entries = try store.getEntries(
            at: start,
            matching: NSPredicate(format: "subsystem == %@", "com.inscribe.app")
        )

        let logs = entries.compactMap { $0 as? OSLogEntryLog }.map {
            Entry(date: $0.date, category: $0.category, level: $0.level, message: $0.composedMessage)
        }

        return logs.suffix(limit)
    }

    /// The same lines as plain text, for handing to someone who can read them.
    static func asText(_ entries: [Entry]) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"

        return entries
            .map { "\(formatter.string(from: $0.date))  \($0.category)  \($0.message)" }
            .joined(separator: "\n")
    }
}
