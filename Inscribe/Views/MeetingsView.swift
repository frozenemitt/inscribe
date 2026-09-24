import SwiftUI
import os
import SwiftData

#if os(macOS)
import AppKit

/// Browse recorded meetings, read them by speaker, rename speakers, and export.
struct MeetingsView: View {
    @Environment(MeetingRecorder.self) private var recorder
    @Environment(TranscriptionEngine.self) private var engine
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Meeting.startedAt, order: .reverse) private var meetings: [Meeting]

    @State private var selection: Meeting?

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                // Losing a meeting the user believed was saved is the worst outcome
                // here, so a store that is not writing to disk says so up front.
                if !MeetingStoreStatus.shared.isPersistent {
                    Label(
                        "Meetings are not being saved to disk and will be lost when you quit.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red)
                    .help(MeetingStoreStatus.shared.failureReason ?? "")
                }

                sidebar
            }
        } detail: {
            if let meeting = selection ?? recorder.activeMeeting {
                // A new view per meeting. Reused, it carried the previous meeting's
                // summary state across: click Generate on one, click another, and the
                // second one's button span and stayed disabled until the first
                // finished — and showed the first one's failure under its heading.
                MeetingDetailView(meeting: meeting)
                    .id(meeting.persistentModelID)
            } else {
                ContentUnavailableView(
                    "No Meeting Selected",
                    systemImage: "person.2.wave.2",
                    description: Text("Start a meeting, or pick one from the list.")
                )
            }
        }
        .navigationTitle("Meetings")
        .frame(minWidth: 720, minHeight: 460)
        .onChange(of: recorder.activeMeeting) { _, meeting in
            // Follow the meeting being recorded, so the live transcript is on screen.
            if let meeting { selection = meeting }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            if meetings.isEmpty {
                Text("No meetings yet")
                    .foregroundStyle(.secondary)
            }

            ForEach(meetings) { meeting in
                MeetingRow(
                    meeting: meeting,
                    isRecording: meeting == recorder.activeMeeting,
                    isPaused: recorder.isPaused
                )
                    .tag(meeting)
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            delete(meeting)
                        }
                        // The meeting being prepared is already in this list and is not
                        // named by activeMeeting until it records, so deleting during
                        // "Preparing…" hands the recorder a model the store has dropped.
                        .disabled(meeting == recorder.activeMeeting || recorder.state == .preparing)
                    }
            }
        }
        .frame(minWidth: 220)
        .toolbar {
            ToolbarItem {
                recordButton
            }
        }
    }

    @ViewBuilder
    private var recordButton: some View {
        switch recorder.state {
        case .idle:
            Button {
                Task { await recorder.start(in: modelContext) }
            } label: {
                Label("Start Meeting", systemImage: "record.circle")
            }
            // A dictation holds the same microphone. Without this the button looked
            // available, did nothing when clicked, and said nothing about why.
            .disabled(engine.isBusy)
            .help(engine.isBusy ? "Inscribe is dictating. Finish that first." : "")

        case .preparing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Preparing…")
                    .font(.caption)
            }

        case .recording:
            HStack(spacing: 8) {
                Button {
                    Task { await recorder.pause() }
                } label: {
                    Label("Pause", systemImage: "pause.circle")
                }

                Button {
                    Task { await recorder.stop(in: modelContext) }
                } label: {
                    Label("Stop", systemImage: "stop.circle.fill")
                }
                .tint(.red)
            }

        case .paused:
            HStack(spacing: 8) {
                Button {
                    Task { await recorder.resume() }
                } label: {
                    Label("Resume", systemImage: "play.circle")
                }

                Button {
                    Task { await recorder.stop(in: modelContext) }
                } label: {
                    Label("Stop", systemImage: "stop.circle.fill")
                }
                .tint(.red)
            }

        case .finishing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Saving…")
                    .font(.caption)
            }
        }
    }

    private func delete(_ meeting: Meeting) {
        if selection == meeting { selection = nil }
        // The recording is not owned by SwiftData, so cascade delete does not reach it.
        MeetingAudioStore.delete(fileNamed: meeting.audioFileName)
        modelContext.delete(meeting)
        modelContext.saveOrLog()
    }
}

// MARK: - Row

private struct MeetingRow: View {
    let meeting: Meeting
    let isRecording: Bool
    var isPaused: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if isRecording {
                    Image(systemName: isPaused ? "pause.circle.fill" : "record.circle.fill")
                        .foregroundStyle(isPaused ? .orange : .red)
                        .symbolEffect(.pulse, options: .repeating, isActive: !isPaused)
                }
                Text(meeting.title)
                    .lineLimit(1)
            }

            HStack(spacing: 6) {
                Text(meeting.startedAt, style: .date)
                if meeting.endedAt != nil {
                    Text("·")
                    Text(MeetingExporter.durationLabel(meeting.duration))
                }
                if meeting.hasSpeakerAttribution {
                    Text("·")
                    Label("\(meeting.speakers.count)", systemImage: "person.2")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Detail

private struct MeetingDetailView: View {
    @Bindable var meeting: Meeting

    @Environment(MeetingRecorder.self) private var recorder
    @Environment(\.modelContext) private var modelContext

    @State private var isSummarizing = false
    @State private var summaryError: String?
    @State private var splitTarget: Utterance?
    @State private var player = MeetingPlayer()

    private var isLive: Bool { meeting == recorder.activeMeeting && recorder.hasActiveMeeting }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if isLive {
                    liveTranscript
                } else {
                    if let error = recorder.lastError, meeting.utterances.isEmpty {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    speakerNames
                    playbackBar
                    summarySection
                    transcript
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: meeting.persistentModelID) { _, _ in
            // Reloaded, not just unloaded. `.onAppear` does not fire again when the
            // subtree is structurally unchanged, so the bar sat at 0:00 with a dead
            // scrubber until the user pressed Play.
            player.unload()
            player.load(fileName: meeting.audioFileName)
        }
        .onDisappear { player.unload() }
        .sheet(item: $splitTarget) { utterance in
            SplitUtteranceSheet(meeting: meeting, utterance: utterance) { offset, speaker in
                _ = meeting.split(
                    utterance,
                    atCharacterOffset: offset,
                    assigningTailTo: speaker,
                    in: modelContext
                )
                finishCorrection()
                splitTarget = nil
            } onCancel: {
                splitTarget = nil
            }
        }
        .toolbar {
            if !isLive {
                ToolbarItem {
                    Menu {
                        ForEach(MeetingExporter.Format.allCases) { format in
                            Button("Save as \(format.displayName)…") { save(as: format) }
                        }
                        Divider()
                        Button("Copy Transcript") {
                            ClipboardService.copy(MeetingExporter.plainText(meeting))
                        }
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Title", text: $meeting.title)
                .textFieldStyle(.plain)
                .font(.largeTitle.bold())
                .onSubmit { modelContext.saveOrLog() }

            HStack(spacing: 8) {
                Text(meeting.startedAt.formatted(date: .abbreviated, time: .shortened))
                if meeting.endedAt != nil {
                    Text("·")
                    Text(MeetingExporter.durationLabel(meeting.duration))
                }
                if meeting.wasPaused {
                    Text("·")
                    Text("\(MeetingExporter.durationLabel(meeting.recordedDuration)) recorded")
                }
                if !isLive && !meeting.hasSpeakerAttribution {
                    Text("·")
                    Text("no speaker separation")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    private var liveTranscript: some View {
        VStack(alignment: .leading, spacing: 12) {
            if recorder.isPaused {
                Label("Paused", systemImage: "pause.circle.fill")
                    .foregroundStyle(.orange)
            } else {
                Label("Recording", systemImage: "record.circle.fill")
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse, options: .repeating)
            }

            Text(recorder.liveTranscript.isEmpty ? "Listening…" : recorder.liveTranscript)
                .textSelection(.enabled)
                .foregroundStyle(recorder.liveTranscript.isEmpty ? .secondary : .primary)

            Text("Speakers are separated once the meeting ends — attribution needs the whole recording to tell voices apart reliably.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var speakerNames: some View {
        if meeting.hasSpeakerAttribution {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Speakers")
                        .font(.headline)
                    Spacer()
                    Button("Add Speaker") {
                        _ = meeting.addSpeaker(in: modelContext)
                        modelContext.saveOrLog()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }

                ForEach(meeting.speakers.sorted { $0.generatedLabel < $1.generatedLabel }) { speaker in
                    HStack {
                        Text(speaker.generatedLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 90, alignment: .leading)

                        TextField("Name", text: Binding(
                            get: { speaker.name },
                            set: { speaker.name = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { modelContext.saveOrLog() }

                        Text("\(utteranceCount(for: speaker)) lines")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()

                        // For when the diarizer split one person into two.
                        Menu {
                            ForEach(meeting.speakers.filter { $0.speakerId != speaker.speakerId }) { other in
                                Button("Merge into \(other.resolvedName)") {
                                    meeting.merge(speaker, into: other, in: modelContext)
                                    modelContext.saveOrLog()
                                }
                            }
                        } label: {
                            Image(systemName: "arrow.triangle.merge")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .disabled(meeting.speakers.count < 2)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Summary")
                    .font(.headline)
                Spacer()
                Button {
                    summarize()
                } label: {
                    if isSummarizing {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(meeting.summary == nil ? "Generate" : "Regenerate")
                    }
                }
                .disabled(isSummarizing)
            }

            // Above the summary rather than instead of it: a failed Regenerate leaves
            // the previous summary on screen, and the failure has to be visible there.
            if let summaryError {
                Text(summaryError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if let summary = meeting.summary, !summary.isEmpty {
                Text(summary)
                    .textSelection(.enabled)
            } else if summaryError == nil {
                Text("Runs the transcript through your selected prompt, on-device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var transcript: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Transcript")
                .font(.headline)

            if meeting.hasSpeakerAttribution {
                Text("Click a speaker name to correct who said it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                let hasAudio = meeting.hasAudio

                ForEach(meeting.orderedUtterances) { utterance in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            speakerMenu(for: utterance)

                            // Hearing the moment is the only way to know whether an
                            // attribution is right, so the timestamp plays it.
                            if hasAudio {
                                Button {
                                    player.load(fileName: meeting.audioFileName)
                                    player.play(from: utterance)
                                } label: {
                                    HStack(spacing: 3) {
                                        Image(systemName: "play.circle")
                                        Text(utterance.timestampLabel)
                                            .monospacedDigit()
                                    }
                                    .font(.caption)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .help("Play from here")
                            } else {
                                Text(utterance.timestampLabel)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                        Text(utterance.text)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 3)
                    .padding(.horizontal, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(player.isPlaying(utterance)
                                  ? Color.accentColor.opacity(0.12) : .clear)
                    )
                }
            } else if meeting.rawTranscript.isEmpty {
                Text("No transcript was captured.")
                    .foregroundStyle(.secondary)
            } else {
                Text(meeting.rawTranscript)
                    .textSelection(.enabled)
            }
        }
    }

    private func utteranceCount(for speaker: MeetingSpeaker) -> Int {
        meeting.utterances.count { $0.speakerId == speaker.speakerId }
    }

    @ViewBuilder
    private var playbackBar: some View {
        if meeting.hasAudio {
            HStack(spacing: 12) {
                Button {
                    player.load(fileName: meeting.audioFileName)
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)

                Text(MeetingPlayer.timeLabel(player.currentTime))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                Slider(
                    value: Binding(
                        get: { player.currentTime },
                        set: { player.seek(to: $0) }
                    ),
                    in: 0...max(player.duration, 1)
                )

                Text(MeetingPlayer.timeLabel(player.duration))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                Text(MeetingAudioStore.formatted(bytes: MeetingAudioStore.size(ofFileNamed: meeting.audioFileName)))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
            .onAppear { player.load(fileName: meeting.audioFileName) }

            // A recording that will not open used to leave a bar whose button did
            // nothing, with the reason only in the log.
            if let error = player.lastError {
                Label("The recording could not be opened: \(error)", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } else if meeting.endedAt != nil {
            Text("No recording was kept for this meeting.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Corrections

    /// Reassign, or cut an utterance that holds two people.
    private func speakerMenu(for utterance: Utterance) -> some View {
        Menu {
            Section("Attribute to") {
                ForEach(meeting.speakers.sorted { $0.generatedLabel < $1.generatedLabel }) { speaker in
                    Button {
                        meeting.reassign(utterance, to: speaker)
                        finishCorrection()
                    } label: {
                        if speaker.speakerId == utterance.speakerId {
                            Label(speaker.resolvedName, systemImage: "checkmark")
                        } else {
                            Text(speaker.resolvedName)
                        }
                    }
                }
            }

            Divider()

            Button("Attribute to a New Speaker") {
                let speaker = meeting.addSpeaker(in: modelContext)
                meeting.reassign(utterance, to: speaker)
                finishCorrection()
            }

            if !UtteranceSplitPoint.candidates(in: utterance.text).isEmpty {
                Button("Split This Line...") {
                    splitTarget = utterance
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(meeting.displayName(forSpeakerId: utterance.speakerId))
                    .font(.subheadline.bold())
                Image(systemName: "chevron.down")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// Save, and drop any speaker left with nothing attributed to them.
    private func finishCorrection() {
        meeting.pruneEmptySpeakers(in: modelContext)
        modelContext.saveOrLog()
    }

    // MARK: Actions

    private func summarize() {
        isSummarizing = true
        summaryError = nil

        Task {
            do {
                try await recorder.summarize(meeting, in: modelContext)
            } catch {
                summaryError = error.localizedDescription
            }
            isSummarizing = false
        }
    }

    private func save(as format: MeetingExporter.Format) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(meeting.title).\(format.fileExtension)"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try MeetingExporter.export(meeting, as: format).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Log.meetings.error("Export failed: \(error, privacy: .public)")
        }
    }
}
#endif

// MARK: - Split Sheet

#if os(macOS)
/// Cut one block of text into two speakers.
///
/// Offers sentence boundaries rather than a free cursor: a missed handover almost
/// always falls at the end of a sentence, and picking from a short list is faster
/// than placing a caret in a wall of text.
private struct SplitUtteranceSheet: View {
    let meeting: Meeting
    let utterance: Utterance
    let onSplit: (Int, MeetingSpeaker?) -> Void
    let onCancel: () -> Void

    @State private var selectedOffset: Int?
    @State private var tailSpeaker: MeetingSpeaker?

    private var candidates: [(offset: Int, preview: String)] {
        UtteranceSplitPoint.candidates(in: utterance.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Split This Line")
                .font(.headline)

            Text("Currently all attributed to \(meeting.displayName(forSpeakerId: utterance.speakerId)). Choose where the next speaker starts.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(candidates, id: \.offset) { candidate in
                        Button {
                            selectedOffset = candidate.offset
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: selectedOffset == candidate.offset
                                      ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(selectedOffset == candidate.offset ? Color.accentColor : .secondary)
                                Text("…\(candidate.preview)")
                                    .multilineTextAlignment(.leading)
                                    .foregroundStyle(.primary)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 180)

            Picker("Second half is", selection: $tailSpeaker) {
                Text("A new speaker").tag(nil as MeetingSpeaker?)
                ForEach(meeting.speakers.sorted { $0.generatedLabel < $1.generatedLabel }) { speaker in
                    Text(speaker.resolvedName).tag(speaker as MeetingSpeaker?)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Split") {
                    guard let selectedOffset else { return }
                    onSplit(selectedOffset, tailSpeaker)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedOffset == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
#endif
