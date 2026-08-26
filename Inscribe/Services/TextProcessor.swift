import Foundation

/// Rewrites a raw transcript before it is delivered.
///
/// Runs before the AI pass, so a corrected term reaches the model already spelled the
/// way you want it rather than being "fixed" back to whatever the transcriber heard.
enum TextProcessor {

    /// Apply spoken punctuation and the user's replacement list, in that order.
    static func process(
        _ text: String,
        spokenPunctuation: Bool,
        replacements: [String: String]
    ) -> String {
        var result = text

        // Punctuation first: a replacement whose target contains a comma or period
        // should survive, not get eaten by the punctuation pass.
        if spokenPunctuation {
            result = applySpokenPunctuation(to: result)
        }

        if !replacements.isEmpty {
            result = applyReplacements(replacements, to: result)
        }

        return result
    }

    // MARK: - Spoken Punctuation

    /// Phrases that become punctuation when spoken.
    ///
    /// Ordered longest-first: "question mark" has to win before "mark" or the bare
    /// word would strand a stray "question".
    private static let punctuation: [(phrase: String, mark: String, eatsFollowingSpace: Bool)] = [
        ("new paragraph", "\n\n", true),
        ("new line", "\n", true),
        ("exclamation point", "!", false),
        ("exclamation mark", "!", false),
        ("question mark", "?", false),
        ("open parenthesis", "(", true),
        ("close parenthesis", ")", false),
        ("open quote", "\u{201C}", true),
        ("close quote", "\u{201D}", false),
        ("semicolon", ";", false),
        ("ellipsis", "\u{2026}", false),
        ("full stop", ".", false),
        ("colon", ":", false),
        ("comma", ",", false),
        ("period", ".", false),
        ("hyphen", "-", true)
    ]

    private static func applySpokenPunctuation(to text: String) -> String {
        var result = text

        for entry in punctuation {
            // Swallow the space before the mark, so "hello period" reads "hello."
            // rather than "hello ." Line breaks swallow the trailing space too.
            let trailing = entry.eatsFollowingSpace ? "\\s*" : ""
            let pattern = "\\s*\\b\(NSRegularExpression.escapedPattern(for: entry.phrase))\\b\(trailing)"

            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }

            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: NSRegularExpression.escapedTemplate(for: entry.mark)
            )
        }

        return result
    }

    // MARK: - Word Replacements

    /// Case-insensitive whole-word substitution.
    ///
    /// Whole-word only, so a replacement for "vox" cannot corrupt "voxel".
    private static func applyReplacements(_ replacements: [String: String], to text: String) -> String {
        var result = text

        // Longest source first, so a more specific phrase wins over a prefix of itself.
        for (source, replacement) in replacements.sorted(by: { $0.key.count > $1.key.count }) {
            let trimmed = source.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: trimmed))\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }

            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: NSRegularExpression.escapedTemplate(for: replacement)
            )
        }

        return result
    }
}
