import Foundation

/// Keeps the speaker's words when a prompt is meant to correct them, not rewrite them.
///
/// Apple's on-device model drops or rewords words even when told not to. Measured on
/// real dictations with a prompt that forbids it, and under greedy sampling, so every
/// time: "update that yet" came back as "update that", "a reference point" as "a
/// reference", and one version lost the whole end of a dictation. No wording of the
/// prompt stopped it without causing a different loss somewhere else.
///
/// So the rule is enforced here instead. The rewrite is lined up against what was
/// said, word by word, and only what a correction may change gets through:
/// punctuation and capitals, an accidental repeat taken out, and a word swapped
/// one-for-one for another (a misheard word). A word the model dropped is put back; a
/// word it added, or a phrase it reworded, goes back to what was said.
///
/// Lining up 400 words, about two minutes of speech, takes under half a millisecond.
enum WordGuard {

    struct Outcome {
        let text: String
        /// Words put back that the model had dropped or reworded.
        let restored: Int
        /// Words the model added that were taken out.
        let removed: Int
    }

    /// Past this many words the check is skipped: lining up is quadratic, and a
    /// dictation this long is rare enough not to hold the paste up for it.
    static let maximumWords = 2000

    static func apply(said: String, rewrite: String) -> Outcome {
        let saidWords = words(in: said)
        let rewriteWords = words(in: rewrite)
        guard !saidWords.isEmpty, !rewriteWords.isEmpty,
              saidWords.count <= maximumWords, rewriteWords.count <= maximumWords else {
            return Outcome(text: rewrite, restored: 0, removed: 0)
        }

        var output: [Word] = []
        var restored = 0
        var removed = 0

        for step in alignment(saidWords.map(\.key), rewriteWords.map(\.key)) {
            switch step {
            case .same(let j):
                output.append(rewriteWords[j])

            case .changed(let said, let rewritten):
                if !said.isEmpty, said.count == rewritten.count {
                    // One-for-one swaps: the misheard words a correction exists to fix.
                    output += rewritten.map { rewriteWords[$0] }
                } else if rewritten.isEmpty {
                    // Dropped words come back, except an accidental repeat.
                    let back = said.filter { !isRepeat(at: $0, in: saidWords) }
                    output += restoring(back.map { saidWords[$0] }, after: output)
                    restored += back.count
                } else if said.isEmpty {
                    // Words the model added are left out.
                    removed += rewritten.count
                } else {
                    // A phrase reworded into a different number of words goes back to
                    // what was said: "there's" stays "there's", not "there are".
                    output += restoring(said.map { saidWords[$0] }, after: output)
                    restored += said.count
                    removed += rewritten.count
                }
            }
        }

        return Outcome(text: joined(output), restored: restored, removed: removed)
    }

    // MARK: - Words

    /// A word as written, the space that followed it, and the form compared.
    private struct Word {
        var text: String
        var spaceAfter: String
        let key: String
        /// Put back from what was said. Seams are mended only next to these, never
        /// inside the model's own text.
        var isRestored = false
    }

    private static func words(in text: String) -> [Word] {
        var result: [Word] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard !text[index].isWhitespace else { index = text.index(after: index); continue }
            let start = index
            while index < text.endIndex, !text[index].isWhitespace { index = text.index(after: index) }
            let end = index
            while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
            let token = String(text[start..<end])
            let key = token.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "’" }
                .replacingOccurrences(of: "’", with: "'")
            if key.isEmpty {
                // Punctuation standing alone, such as a dash: kept with the word before.
                if !result.isEmpty {
                    result[result.count - 1].spaceAfter += token + String(text[end..<index])
                }
                continue
            }
            result.append(Word(text: token, spaceAfter: String(text[end..<index]), key: key))
        }
        return result
    }

    private static func isRepeat(at index: Int, in words: [Word]) -> Bool {
        (index > 0 && words[index - 1].key == words[index].key)
            || (index + 1 < words.count && words[index + 1].key == words[index].key)
    }

    /// Said words put back into the rewrite, fitted to where they land.
    ///
    /// A pause ellipsis on a said word is dropped. Where the model had ended a
    /// sentence at the gap, and the words coming back carry on that sentence, the
    /// early full stop goes. At the very start, the first word takes a capital.
    private static func restoring(_ said: [Word], after output: [Word]) -> [Word] {
        var back = said.map { word -> Word in
            var word = word
            word.text = word.text.replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "")
            word.spaceAfter = " "
            word.isRestored = true
            return word
        }
        guard !back.isEmpty else { return back }

        if output.isEmpty {
            back[0].text = capitalizingFirst(back[0].text)
        }
        return back
    }

    /// The words joined, with the seams around restored words mended.
    private static func joined(_ words: [Word]) -> String {
        var words = words
        for i in words.indices.dropFirst() {
            let previous = words[i - 1].text
            let current = words[i].text
            // A full stop the model put before a restored word that carries the
            // sentence on.
            if words[i].isRestored, !words[i - 1].isRestored,
               let last = previous.last, ".?!".contains(last),
               let first = current.first, first.isLowercase {
                words[i - 1].text.removeLast()
            }
            // A capital on a common word that no longer starts a sentence, now that
            // the words before it are back. Either the model gave it one, having made
            // the word start a sentence, or it is a restored word with the capital the
            // recognizer gave it for coming after a pause.
            if words[i - 1].isRestored || words[i].isRestored,
               let last = previous.last, !".?!:".contains(last),
               commonWords.contains(current.lowercased().trimmingCharacters(in: .punctuationCharacters)),
               let first = current.first, first.isUppercase {
                words[i].text = current.prefix(1).lowercased() + current.dropFirst()
            }
        }
        var text = ""
        for (i, word) in words.enumerated() {
            text += word.text
            if i < words.count - 1 { text += word.spaceAfter.isEmpty ? " " : word.spaceAfter }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func capitalizingFirst(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    /// Words that take a capital only at the start of a sentence.
    private static let commonWords: Set<String> = [
        "a", "an", "the", "and", "but", "or", "so", "of", "to", "in", "on", "at", "for",
        "with", "it", "its", "it's", "this", "that", "these", "those", "we", "you",
        "they", "he", "she", "is", "are", "was", "were", "be", "let's", "let", "there",
        "their", "then", "just", "not", "no", "if", "as", "by", "from", "my", "our",
        "your", "what", "which", "who", "when", "where", "how", "why", "can", "could",
        "would", "should", "will", "do", "does", "did", "have", "has", "had", "all",
        "some", "any"
    ]

    // MARK: - Alignment

    private enum Step {
        /// The word at this index of the rewrite matches what was said.
        case same(Int)
        /// Said words and rewrite words between two matches.
        case changed(said: [Int], rewritten: [Int])
    }

    /// The longest common run of words, as matches and the gaps between them.
    private static func alignment(_ a: [String], _ b: [String]) -> [Step] {
        let n = a.count, m = b.count
        var lengths = [Int32](repeating: 0, count: (n + 1) * (m + 1))
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lengths[i * (m + 1) + j] = a[i] == b[j]
                    ? lengths[(i + 1) * (m + 1) + j + 1] + 1
                    : max(lengths[(i + 1) * (m + 1) + j], lengths[i * (m + 1) + j + 1])
            }
        }

        var steps: [Step] = []
        var said: [Int] = [], rewritten: [Int] = []
        func closeGap() {
            if !said.isEmpty || !rewritten.isEmpty {
                steps.append(.changed(said: said, rewritten: rewritten))
                said = []; rewritten = []
            }
        }
        var i = 0, j = 0
        while i < n, j < m {
            if a[i] == b[j] {
                closeGap()
                steps.append(.same(j))
                i += 1; j += 1
            } else if lengths[(i + 1) * (m + 1) + j] >= lengths[i * (m + 1) + j + 1] {
                said.append(i); i += 1
            } else {
                rewritten.append(j); j += 1
            }
        }
        said += Array(i..<n)
        rewritten += Array(j..<m)
        closeGap()
        return steps
    }
}
