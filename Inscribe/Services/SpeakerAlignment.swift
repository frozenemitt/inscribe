import Foundation

/// A stretch of speech attributed to one speaker.
struct AlignedUtterance: Sendable, Equatable {
    let speakerId: String
    let text: String
    let start: TimeInterval
    let end: TimeInterval
}

/// Joins what was said to who said it.
///
/// The transcriber and the diarizer analyse the same audio independently and agree on
/// nothing but the clock, so every transcript run is matched to the speaker turn
/// covering the moment it was spoken.
///
/// The previous implementation divided the transcript across speakers *in proportion
/// to how long each spoke*, which produces plausible-looking output that is wrong
/// whenever anyone talks faster than anyone else. This uses real timestamps.
enum SpeakerAlignment {

    /// Identifier used when the diarizer has no opinion about a stretch of speech.
    static let unknownSpeaker = "unknown"

    /// How far a word may sit from the nearest speaker turn and still be credited to it.
    ///
    /// The diarizer drops short stretches it takes for silence, and a word landing in
    /// one of those still belongs to whoever was talking around it. A word further than
    /// this from every turn sits in a stretch the diarizer failed on, such as a chunk
    /// that threw, and crediting it to the nearest turn put a minute of speech in the
    /// mouth of whoever happened to speak next.
    private static let nearestTurnReach: TimeInterval = 2

    /// A silence long enough to start a new utterance even when the speaker has not
    /// changed.
    ///
    /// Without it, one person's lines either side of a long pause became one utterance,
    /// and its single timestamp said nothing about when the later sentences were spoken.
    private static let utteranceBreak: TimeInterval = 3

    /// Attribute each transcript run, then merge neighbours by the same speaker unless
    /// a long silence separates them.
    static func align(
        transcript: [TimedTranscriptSegment],
        turns: [SpeakerTurn]
    ) -> [AlignedUtterance] {

        let ordered = transcript.sorted { $0.start < $1.start }
        guard !ordered.isEmpty else { return [] }

        // No diarization, no attribution. Returning one "unattributed" utterance made
        // `hasSpeakerAttribution` true, which hid both the hint explaining that
        // speaker separation was unavailable and the error saying why — leaving a
        // Speakers list with a single nameless row and no way to find out.
        guard !turns.isEmpty else { return [] }

        let sortedTurns = turns.sorted { $0.start < $1.start }
        var merged: [AlignedUtterance] = []

        for run in ordered {
            let speaker = speakerId(at: run.midpoint, in: sortedTurns)

            // Extend the previous utterance when the speaker has not changed, so the
            // result reads as speech rather than a list of fragments.
            if var last = merged.last, last.speakerId == speaker,
               run.start - last.end < utteranceBreak {
                last = AlignedUtterance(
                    speakerId: speaker,
                    text: joined(last.text, run.text),
                    start: last.start,
                    end: run.end
                )
                merged[merged.count - 1] = last
            } else {
                merged.append(AlignedUtterance(
                    speakerId: speaker,
                    text: run.text,
                    start: run.start,
                    end: run.end
                ))
            }
        }

        return merged.compactMap { utterance in
            let trimmed = utterance.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return AlignedUtterance(
                speakerId: utterance.speakerId,
                text: trimmed,
                start: utterance.start,
                end: utterance.end
            )
        }
    }

    /// Join two runs, putting back a space the transcriber left out.
    ///
    /// Runs inside one result carry their own leading space, but the first run of the
    /// next result does not, so the last word of one result and the first of the next
    /// were fused into one. A run that starts with punctuation is left attached.
    private static func joined(_ first: String, _ second: String) -> String {
        guard let end = first.last, let start = second.first,
              !end.isWhitespace, start.isLetter || start.isNumber else {
            return first + second
        }
        return first + " " + second
    }

    /// Who was speaking at `time`.
    ///
    /// When several turns cover the instant, as they do where people talk over each
    /// other, the shortest wins. Taking the first to start credited the interjection to
    /// whoever had been talking longest, which is exactly the person who did not say it.
    ///
    /// Falls back to the nearest turn when nothing covers the instant, as long as it is
    /// within `nearestTurnReach`: the diarizer drops stretches it considers silence, and
    /// a word landing in one of those gaps still belongs to whoever was talking around
    /// it. Further away than that, the word is left unattributed.
    private static func speakerId(at time: TimeInterval, in turns: [SpeakerTurn]) -> String {
        let covering = turns.filter { $0.covers(time) }
        if let shortest = covering.min(by: { $0.end - $0.start < $1.end - $1.start }) {
            return shortest.speakerId
        }

        let nearest = turns.min { first, second in
            distance(from: time, to: first) < distance(from: time, to: second)
        }

        guard let nearest, distance(from: time, to: nearest) <= nearestTurnReach else {
            return unknownSpeaker
        }
        return nearest.speakerId
    }

    private static func distance(from time: TimeInterval, to turn: SpeakerTurn) -> TimeInterval {
        if time < turn.start { return turn.start - time }
        if time > turn.end { return time - turn.end }
        return 0
    }

    /// Number speakers by when they first spoke, so labels match reading order.
    ///
    /// The diarizer's own ids reflect clustering order, which has no relationship to
    /// the order a reader meets them in.
    static func generatedLabels(for utterances: [AlignedUtterance]) -> [String: String] {
        var labels: [String: String] = [:]
        var next = 1

        for utterance in utterances where labels[utterance.speakerId] == nil {
            if utterance.speakerId == unknownSpeaker {
                labels[utterance.speakerId] = "Unattributed"
            } else {
                labels[utterance.speakerId] = "Speaker \(next)"
                next += 1
            }
        }

        return labels
    }
}
