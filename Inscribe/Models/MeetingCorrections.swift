import Foundation
import SwiftData

/// Hand corrections to what the diarizer decided.
///
/// Diarization gets handovers wrong in three recognisable ways, and each needs a
/// different repair: it credits a stretch to the wrong person (reassign), it splits one
/// person into two (merge), or it misses a handover entirely and runs two people
/// together (split). Nothing here re-runs inference — the user has heard the audio and
/// is simply telling the record what happened.
extension Meeting {

    // MARK: - Reassign

    /// Move an utterance to a different speaker.
    func reassign(_ utterance: Utterance, to speaker: MeetingSpeaker) {
        utterance.speakerId = speaker.speakerId
    }

    // MARK: - Add

    /// Add a speaker the diarizer never separated out.
    ///
    /// Needed when two people were collapsed into one: create the missing speaker,
    /// then reassign their utterances across.
    @discardableResult
    func addSpeaker(in context: ModelContext, named name: String = "") -> MeetingSpeaker {
        let existing = Set(speakers.map(\.speakerId))
        var index = speakers.count + 1
        var identifier = "manual-\(index)"
        while existing.contains(identifier) {
            index += 1
            identifier = "manual-\(index)"
        }

        let label = nextGeneratedLabel()
        let speaker = MeetingSpeaker(speakerId: identifier, generatedLabel: label, name: name)
        speaker.meeting = self
        context.insert(speaker)
        return speaker
    }

    /// The next free "Speaker N", skipping numbers already taken.
    private func nextGeneratedLabel() -> String {
        let taken = Set(speakers.map(\.generatedLabel))
        var number = 1
        while taken.contains("Speaker \(number)") { number += 1 }
        return "Speaker \(number)"
    }

    // MARK: - Merge

    /// Fold `source` into `target`, moving every utterance across.
    ///
    /// For when the diarizer split one person in two — usually because their voice
    /// changed, they moved away from the microphone, or the room got noisy.
    func merge(_ source: MeetingSpeaker, into target: MeetingSpeaker, in context: ModelContext) {
        guard source.speakerId != target.speakerId else { return }

        for utterance in utterances where utterance.speakerId == source.speakerId {
            utterance.speakerId = target.speakerId
        }

        // Keep a name the user typed rather than losing it to the merge.
        if target.name.trimmingCharacters(in: .whitespaces).isEmpty,
           !source.name.trimmingCharacters(in: .whitespaces).isEmpty {
            target.name = source.name
        }

        speakers.removeAll { $0.speakerId == source.speakerId }
        context.delete(source)
    }

    // MARK: - Split

    /// Cut an utterance in two at a character offset, giving the tail to `speaker`.
    ///
    /// For a missed handover, where one block holds two people talking. The time split
    /// is interpolated from how far through the text the cut falls — an approximation,
    /// since the exact instant is not recorded per character, but close enough that the
    /// two halves stay in order and the timestamps stay believable.
    @discardableResult
    func split(
        _ utterance: Utterance,
        atCharacterOffset offset: Int,
        assigningTailTo speaker: MeetingSpeaker?,
        in context: ModelContext
    ) -> Utterance? {

        let text = utterance.text
        guard offset > 0, offset < text.count else { return nil }

        let cut = text.index(text.startIndex, offsetBy: offset)
        let head = String(text[text.startIndex..<cut]).trimmingCharacters(in: .whitespaces)
        let tail = String(text[cut...]).trimmingCharacters(in: .whitespaces)

        guard !head.isEmpty, !tail.isEmpty else { return nil }

        let fraction = Double(offset) / Double(text.count)
        let boundary = utterance.start + (utterance.end - utterance.start) * fraction

        let tailUtterance = Utterance(
            speakerId: speaker?.speakerId ?? utterance.speakerId,
            text: tail,
            start: boundary,
            end: utterance.end
        )
        tailUtterance.meeting = self
        context.insert(tailUtterance)

        utterance.text = head
        utterance.end = boundary

        return tailUtterance
    }

    // MARK: - Cleanup

    /// Drop speakers that no longer have anything attributed to them.
    ///
    /// Reassigning every line away from someone should not leave their name in the
    /// speaker list or the exported header.
    func pruneEmptySpeakers(in context: ModelContext) {
        let used = Set(utterances.map(\.speakerId))
        let orphans = speakers.filter { !used.contains($0.speakerId) }

        for orphan in orphans {
            speakers.removeAll { $0.speakerId == orphan.speakerId }
            context.delete(orphan)
        }
    }
}

// MARK: - Split Points

/// Where an utterance could reasonably be cut.
enum UtteranceSplitPoint {

    /// Sentence ends, offered as candidate cut points.
    ///
    /// A missed handover almost always falls on a sentence boundary, so these are
    /// enough without asking the user to place a cursor mid-word.
    static func candidates(in text: String) -> [(offset: Int, preview: String)] {
        var points: [(Int, String)] = []
        var offset = 0

        let sentences = text.split(omittingEmptySubsequences: false) { $0 == "." || $0 == "?" || $0 == "!" }

        for (index, sentence) in sentences.enumerated() where index < sentences.count - 1 {
            // +1 for the punctuation the split consumed.
            offset += sentence.count + 1

            let after = String(text.dropFirst(offset)).trimmingCharacters(in: .whitespaces)
            guard !after.isEmpty, offset < text.count else { continue }

            points.append((offset, String(after.prefix(60))))
        }

        return points
    }
}
