import Foundation

/// Rewrites a raw transcript before it is delivered.
///
/// Runs before the AI pass, so a corrected term reaches the model already spelled the
/// way you want it rather than being "fixed" back to whatever the transcriber heard.
enum TextProcessor {

    /// Take out the recognizer's pause marks, then apply the user's replacement list.
    ///
    /// Pause marks go first, so an ellipsis or full stop a replacement puts in on
    /// purpose is kept.
    static func process(_ text: String, replacements: [String: String]) -> String {
        let mended = removingPauseMarks(from: text)
        guard !replacements.isEmpty else { return mended }
        return applyReplacements(replacements, to: mended)
    }

    // MARK: - Pause Marks

    /// Apple's recognizer punctuates pauses, not sentences: "people in the audio
    /// space... are very passionate", "any other options. for Models. that we can
    /// implement. locally." Where it carried on in lowercase after the mark, it did not
    /// start a new sentence there either, so the mark goes. A mark before a capital
    /// stays for the AI pass, since "I don't know... Let's go" is a real break.
    ///
    /// Measured on 20 dictations, this fixed the pause marks in 9 and made none worse,
    /// including two that Apple's model misses on its own. A punctuation model tried
    /// in its place split sentences wrongly in 8 of the 20, and where it only judged
    /// the recognizer's marks, it decided every one the way this rule does.
    static func removingPauseMarks(from text: String) -> String {
        let whole = text as NSString
        var result = whole
        // Last first, so a removal leaves the ranges before it where they were.
        for match in pauseMark.matches(in: text, range: NSRange(location: 0, length: whole.length)).reversed() {
            let space = whole.rangeOfCharacter(
                from: .whitespacesAndNewlines, options: .backwards,
                range: NSRange(location: 0, length: match.range.location)
            )
            let wordStart = space.location == NSNotFound ? 0 : NSMaxRange(space)
            let word = whole.substring(with: NSRange(location: wordStart, length: NSMaxRange(match.range) - wordStart))
            if abbreviation.firstMatch(in: word, range: NSRange(location: 0, length: (word as NSString).length)) != nil {
                continue
            }
            result = result.replacingCharacters(in: match.range, with: "") as NSString
        }
        return result as String
    }

    /// An ellipsis, full stop, question mark or exclamation mark ending a word, when the
    /// next word is all lowercase. A word like "iPhone" or "macOS" can start a sentence
    /// in lowercase, so it does not count.
    private static let pauseMark = try! NSRegularExpression(
        pattern: "(?<=\\S)(?:\\.\\.\\.|…|[.?!])(?= +\\p{Ll}+(?!\\p{L}))"
    )

    /// A full stop that belongs to the word: "U.S.", "a.m.", "Dr.", "etc."
    private static let abbreviation = try! NSRegularExpression(
        pattern: "^(?:\\p{L}\\.){2,}$|^(?:Mr|Mrs|Ms|Dr|St|vs|etc|Jr|Sr)\\.$",
        options: [.caseInsensitive]
    )

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
