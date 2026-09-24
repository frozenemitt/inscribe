import SwiftUI
import SwiftData
import AVFoundation
import UniformTypeIdentifiers

#if os(macOS)
import AppKit

/// Turn an existing recording into a transcript, optionally speaker-separated.
///
/// The pipeline already existed for the microphone; this points it at a file. Useful
/// for a meeting someone else recorded, or one recorded before Inscribe was running.
struct ImportRecordingView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var modelContext

    @State private var transcriber = FileTranscriber()
    @State private var diarizer = MeetingDiarizer()

    @State private var droppedURL: URL?
    @State private var separateSpeakers = true
    @State private var progressNote: String?
    @State private var savedMeeting: Meeting?
    @State private var errorMessage: String?
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            dropZone

            if let droppedURL {
                Text(droppedURL.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Toggle("Separate speakers", isOn: $separateSpeakers)
                Text("Runs the same diarization meetings use. Slower, and worth it only when more than one person is talking.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Transcribe") { run(url: droppedURL) }
                        .disabled(transcriber.isBusy || progressNote != nil)
                        .keyboardShortcut(.defaultAction)

                    if let progressNote {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(progressNote).font(.caption)
                        }
                    }
                }
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if let savedMeeting {
                Label("Saved as \"\(savedMeeting.title)\" — open Meetings to read it.",
                      systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            if !transcriber.transcript.isEmpty {
                Divider()
                transcriptPreview
            }

            Spacer()
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 420)
        .navigationTitle("Import Recording")
    }

    // MARK: - Views

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(
                isTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                style: StrokeStyle(lineWidth: 2, dash: [6])
            )
            .frame(height: 110)
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: "waveform.badge.plus")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Drop an audio or video file, or click to choose")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(FileTranscriber.supportedExtensions.joined(separator: "  "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { chooseFile() }
            .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                loadDroppedFile(from: providers)
            }
    }

    private var transcriptPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Transcript")
                    .font(.headline)
                Spacer()
                Button("Copy") { ClipboardService.copy(transcriber.transcript) }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }

            ScrollView {
                Text(transcriber.transcript)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
        }
    }

    // MARK: - File Selection

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .movie]

        guard panel.runModal() == .OK, let url = panel.url else { return }
        accept(url)
    }

    private func loadDroppedFile(from providers: [NSItemProvider]) -> Bool {
        guard !isRunning, let provider = providers.first else { return false }

        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in accept(url) }
        }
        return true
    }

    /// Whether a transcription is under way, from the Transcribe press to the save.
    private var isRunning: Bool { progressNote != nil }

    private func accept(_ url: URL) {
        // Ignored while a run is under way. Accepting resets the transcriber, and a
        // run that was still separating speakers then saved a meeting with no timed
        // runs: no speakers and no length.
        guard !isRunning else { return }

        guard FileTranscriber.supportedExtensions.contains(url.pathExtension.lowercased()) else {
            errorMessage = "\(url.pathExtension.uppercased()) files cannot be read."
            return
        }

        droppedURL = url
        errorMessage = nil
        savedMeeting = nil
        transcriber.reset()
    }

    // MARK: - Running

    private func run(url: URL) {
        errorMessage = nil
        savedMeeting = nil
        // Set before the task starts, so a drop landing before it runs is already
        // turned away.
        progressNote = "Transcribing…"

        Task {
            do {
                let text = try await transcriber.transcribe(
                    fileURL: url,
                    contextualStrings: settings.vocabularyHints
                )
                // Copied at once. The transcriber is shared state, and anything that
                // resets it during the speaker pass would otherwise empty these.
                let segments = transcriber.timedSegments

                var turns: [SpeakerTurn] = []
                if separateSpeakers {
                    progressNote = "Separating speakers…"
                    do {
                        // One diarizer serves every import this window runs, and it
                        // remembers the voices it has heard. Reset first, so the
                        // speakers of the last file are not carried into this one.
                        await diarizer.reset()
                        try await diarizer.prepare()
                        // Decoded off the main actor: reading an hour-long file is one
                        // synchronous pass, and this Task inherits the view's isolation.
                        let samples = try await Task.detached {
                            try AudioFileSamples.read(from: url)
                        }.value
                        turns = await diarizer.diarizeWholeRecording(samples)
                    } catch {
                        // Losing speaker labels should not lose the transcript.
                        errorMessage = "Speaker separation failed: \(error.localizedDescription)"
                    }
                }

                progressNote = "Saving…"
                savedMeeting = save(url: url, transcript: text, segments: segments, turns: turns)
                progressNote = nil

            } catch {
                progressNote = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Store the result as a meeting, so it reads and exports like any other.
    private func save(
        url: URL,
        transcript: String,
        segments: [TimedTranscriptSegment],
        turns: [SpeakerTurn]
    ) -> Meeting {
        let meeting = Meeting(title: url.deletingPathExtension().lastPathComponent)
        modelContext.insert(meeting)

        // Dated backwards from now by the length of the recording. Left at now, the
        // meeting spanned no time at all and every list and export read 0:00.
        //
        // The length is the file's own, its frames over its sample rate. Taken from the
        // last transcribed word, it stopped short of any silence or music at the end.
        let file = try? AVAudioFile(forReading: url)
        let length = file.map { Double($0.length) / $0.fileFormat.sampleRate } ?? 0
        meeting.startedAt = Date().addingTimeInterval(-length)
        meeting.endedAt = Date()
        meeting.rawTranscript = TextProcessor.process(
            transcript,
            replacements: settings.wordReplacements
        )
        meeting.recordedDuration = length

        let aligned = SpeakerAlignment.align(
            transcript: segments,
            turns: turns
        )
        let labels = SpeakerAlignment.generatedLabels(for: aligned)

        for (speakerId, label) in labels {
            let speaker = MeetingSpeaker(speakerId: speakerId, generatedLabel: label)
            speaker.meeting = meeting
            modelContext.insert(speaker)
        }

        // The same pass `rawTranscript` gets. Every reader prefers the utterances once
        // there is attribution, so without this the meeting displays and exports the
        // words "period" and "comma" while the raw transcript has the marks.
        for item in aligned {
            let utterance = Utterance(
                speakerId: item.speakerId,
                text: TextProcessor.process(
                    item.text,
                    replacements: settings.wordReplacements
                ),
                start: item.start,
                end: item.end
            )
            utterance.meeting = meeting
            modelContext.insert(utterance)
        }

        modelContext.saveOrLog()
        return meeting
    }
}
#endif
