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

    /// Attribute each transcript run, then merge neighbours by the same speaker.
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
            if var last = merged.last, last.speakerId == speaker {
                last = AlignedUtterance(
                    speakerId: speaker,
                    text: last.text + run.text,
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

    /// Who was speaking at `time`.
    ///
    /// Falls back to the nearest turn when nothing covers the instant: the diarizer
    /// drops stretches it considers silence, and a word landing in one of those gaps
    /// still belongs to whoever was talking around it.
    private static func speakerId(at time: TimeInterval, in turns: [SpeakerTurn]) -> String {
        if let covering = turns.first(where: { $0.covers(time) }) {
            return covering.speakerId
        }

        let nearest = turns.min { first, second in
            distance(from: time, to: first) < distance(from: time, to: second)
        }

        return nearest?.speakerId ?? unknownSpeaker
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
