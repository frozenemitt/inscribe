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
