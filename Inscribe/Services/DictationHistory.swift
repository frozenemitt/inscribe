import Foundation
import SwiftData
import os

/// Records finished dictations and keeps the list from growing without bound.
///
/// Everything dictated is stored on disk in plain text, which is a real privacy
/// consideration even for an app that never sends anything anywhere. The user can turn
/// it off, and the number kept is theirs to choose.
@MainActor
enum DictationHistory {

    private static let log = Logger(subsystem: "com.inscribe.app", category: "History")

    /// Store a dictation and trim anything past the limit.
    static func record(
        text: String,
        rawText: String?,
        destination: String?,
        promptName: String?,
        settings: AppSettings,
        in context: ModelContext
    ) {
        guard settings.keepDictationHistory else { return }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let entry = Dictation(
            text: text,
            rawText: rawText == text ? nil : rawText,
            destination: destination,
            promptName: promptName
        )
        context.insert(entry)

        prune(to: settings.dictationHistoryLimit, in: context)
        try? context.save()
    }

    /// Drop the oldest entries beyond `limit`.
    static func prune(to limit: Int, in context: ModelContext) {
        guard limit > 0 else { return }

        // Uncapped on purpose: a fetch limited to N entries can never contain an
        // entry past N, so the highest limit the user can pick would never prune.
        let descriptor = FetchDescriptor<Dictation>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )

        guard let entries = try? context.fetch(descriptor), entries.count > limit else { return }

        for entry in entries.dropFirst(limit) {
            context.delete(entry)
        }
        log.debug("Pruned history to \(limit)")
    }

    /// Remove everything.
    static func clear(in context: ModelContext) {
        guard let entries = try? context.fetch(FetchDescriptor<Dictation>()) else { return }
        for entry in entries {
            context.delete(entry)
        }
        try? context.save()
    }
}
