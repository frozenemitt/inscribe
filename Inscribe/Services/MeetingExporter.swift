import Foundation

/// Renders a meeting for reading, copying, or saving to disk.
enum MeetingExporter {

    enum Format: String, CaseIterable, Identifiable {
        case markdown
        case plainText

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .markdown: "Markdown"
            case .plainText: "Plain Text"
            }
        }

        var fileExtension: String {
            switch self {
            case .markdown: "md"
            case .plainText: "txt"
            }
        }
    }

    static func export(_ meeting: Meeting, as format: Format) -> String {
        switch format {
        case .markdown: markdown(meeting)
        case .plainText: plainText(meeting)
        }
    }

    /// Speaker-labelled transcript, no markup. Also what the AI summary reads.
    static func plainText(_ meeting: Meeting) -> String {
        var lines: [String] = []

        if meeting.hasSpeakerAttribution {
            for utterance in meeting.orderedUtterances {
                let name = meeting.displayName(forSpeakerId: utterance.speakerId)
                lines.append("[\(utterance.timestampLabel)] \(name): \(utterance.text)")
            }
        } else {
            lines.append(meeting.rawTranscript)
        }

        return lines.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func markdown(_ meeting: Meeting) -> String {
        var out = "# \(meeting.title)\n\n"

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .full
        dateFormatter.timeStyle = .short

        out += "**Recorded:** \(dateFormatter.string(from: meeting.startedAt))  \n"
        out += "**Duration:** \(durationLabel(meeting.duration))  \n"

        if meeting.hasSpeakerAttribution {
            let names = meeting.speakers
                .sorted { $0.generatedLabel < $1.generatedLabel }
                .map(\.resolvedName)
            out += "**Speakers:** \(names.joined(separator: ", "))  \n"
        }

        out += "\n"

        if let summary = meeting.summary, !summary.isEmpty {
            out += "## Summary\n\n\(summary)\n\n"
        }

        out += "## Transcript\n\n"

        if meeting.hasSpeakerAttribution {
            for utterance in meeting.orderedUtterances {
                let name = meeting.displayName(forSpeakerId: utterance.speakerId)
                out += "**\(name)** *(\(utterance.timestampLabel))*\n\n\(utterance.text)\n\n"
            }
        } else {
            out += meeting.rawTranscript + "\n"
        }

        return out
    }

    static func durationLabel(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}
