import Foundation

/// Rewrites a raw transcript before it is delivered.
///
/// Runs before the AI pass, so a corrected term reaches the model already spelled the
/// way you want it rather than being "fixed" back to whatever the transcriber heard.
enum TextProcessor {

    /// Apply the user's replacement list.
    static func process(_ text: String, replacements: [String: String]) -> String {
        guard !replacements.isEmpty else { return text }
        return applyReplacements(replacements, to: text)
    }

    // MARK: - Word Replacements

    /// Case-insensitive whole-word substitution.
    ///
    /// Whole-word only, so a replacement for "vox" cannot corrupt "voxel". The edges
    /// are "no letter or digit next to it" rather than `\b`, which needs a letter or
    /// digit at each end and so never matched a term like "C++" or ".NET".
    private static func applyReplacements(_ replacements: [String: String], to text: String) -> String {
        var result = text

        // Longest source first, so a more specific phrase wins over a prefix of itself.
        // Equal lengths go alphabetically: a dictionary's own order changes from one
        // launch to the next, and so did the result of two replacements that chain.
        let ordered = replacements.sorted {
            $0.key.count != $1.key.count ? $0.key.count > $1.key.count : $0.key < $1.key
        }
        for (source, replacement) in ordered {
            let trimmed = source.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let pattern = "(?<![\\p{L}\\p{N}_])\(NSRegularExpression.escapedPattern(for: trimmed))(?![\\p{L}\\p{N}_])"
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
