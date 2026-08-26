import Foundation
import SwiftData

/// A finished dictation, kept so it can be recovered.
///
/// Dictation used to be delivered and forgotten, which is fine until the text lands in
/// the wrong window — a menu that stole focus, the wrong tab — and the words are simply
/// gone. Everything said is already on this Mac; keeping the last few is what makes
/// that recoverable.
@Model
final class Dictation {

    /// The text as delivered, after replacements and any AI pass.
    var text: String

    /// The raw transcript before AI processing, when the two differ.
    ///
    /// Kept because the AI occasionally rewrites something better left alone, and the
    /// original is unrecoverable otherwise.
    var rawText: String?

    var createdAt: Date

    /// Where it went — an app name, or "Clipboard".
    var destination: String?

    /// Name of the prompt applied, if any.
    var promptName: String?

    init(
        text: String,
        rawText: String? = nil,
        destination: String? = nil,
        promptName: String? = nil,
        createdAt: Date = Date()
    ) {
        self.text = text
        self.rawText = rawText
        self.destination = destination
        self.promptName = promptName
        self.createdAt = createdAt
    }

    var characterCount: Int { text.count }

    /// Whether the AI changed anything, so the UI can offer the original.
    var wasEditedByAI: Bool {
        guard let rawText else { return false }
        return rawText != text
    }

    /// First line, trimmed, for a list row.
    var preview: String {
        let firstLine = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", maxSplits: 1)
            .first
            .map(String.init) ?? ""
        return firstLine.count > 120 ? String(firstLine.prefix(120)) + "…" : firstLine
    }
}
