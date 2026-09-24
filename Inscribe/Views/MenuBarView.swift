import SwiftUI
import SwiftData

#if os(macOS)

/// The main menu bar interface for the transcription tool
struct MenuBarView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(PromptConfiguration.self) private var promptConfig
    @Environment(TranscriptionEngine.self) private var transcriptionEngine
    @Environment(AIProcessor.self) private var aiProcessor
    @Environment(RecordingCoordinator.self) private var coordinator
    @Environment(MeetingRecorder.self) private var meetingRecorder
    @Environment(\.openWindow) private var openWindow
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Status section
            statusSection

            Divider()
                .padding(.vertical, 4)

            // Recording control
            recordingButton

            Divider()
                .padding(.vertical, 4)

            // Prompt selection
            promptSection

            Divider()
                .padding(.vertical, 4)

            // Quick toggles
            quickToggles

            Divider()
                .padding(.vertical, 4)

            // Meetings
            meetingSection

            Divider()
                .padding(.vertical, 4)

            // Footer actions
            footerSection
        }
        .padding(8)
        .frame(width: 280)
    }

    // MARK: - Status Section

    private var statusSection: some View {
        HStack {
            Image(systemName: statusIcon)
                .font(.title2)
                .foregroundStyle(statusColor)
                .symbolEffect(.pulse, options: .repeating, isActive: transcriptionEngine.isRecording)

            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(.headline)

                Text(statusSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var statusIcon: String {
        if transcriptionEngine.isRecording {
            return "mic.fill"
        } else if aiProcessor.isProcessing {
            return "brain"
        } else {
            return "mic"
        }
    }

    private var statusColor: Color {
        if transcriptionEngine.isRecording {
            return .red
        } else if aiProcessor.isProcessing {
            return .orange
        } else {
            return .secondary
        }
    }

    private var statusTitle: String {
        if meetingRecorder.isPaused {
            return "Meeting paused"
        } else if meetingRecorder.isRecording {
            return "Meeting in progress"
        } else if transcriptionEngine.isRecording {
            return "Recording..."
        } else if aiProcessor.isProcessing {
            return "Processing..."
        } else {
            return "Ready"
        }
    }

    private var statusSubtitle: String {
        if transcriptionEngine.isRecording {
            let charCount = transcriptionEngine.currentTranscript.count + transcriptionEngine.volatileText.count
            return "\(charCount) characters"
        } else if aiProcessor.isProcessing {
            return "Applying AI prompt..."
        } else {
            if let destination = coordinator.lastDestination {
                return "Last result went to \(destination)"
            }
            return "\(activationHint) \(triggerLabel)"
        }
    }

    // MARK: - Recording Button

    /// The engine is busy with something that is not a dictation — a meeting.
    ///
    /// Asked of the coordinator rather than the engine: `transcriptionEngine.isRecording`
    /// is true for meetings too, which had this button offering to stop a recording it
    /// could not stop and then refusing the click in silence.
    private var blockedByMeeting: Bool {
        transcriptionEngine.isBusy && !coordinator.isRecording
    }

    private var recordingButton: some View {
        Button {
            Task {
                await toggleRecording()
            }
        } label: {
            HStack {
                Image(systemName: coordinator.isRecording ? "stop.fill" : "record.circle")
                    .font(.title3)
                    .foregroundStyle(coordinator.isRecording ? .red : .primary)

                Text(coordinator.isRecording ? "Stop Recording" : "Start Recording")
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(triggerLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(coordinator.isRecording ? Color.red.opacity(0.1) : Color.clear)
        )
        .disabled(aiProcessor.isProcessing || blockedByMeeting)
        .help(blockedByMeeting ? "A meeting is using the microphone." : "")
    }

    // MARK: - Prompt Section

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AI Prompt")
                .font(.caption)
                .foregroundStyle(.secondary)

            Menu {
                // A nil selectedPromptId means the default prompt, not "nothing
                // selected" — comparing against the id directly left the default
                // showing no checkmark at all while it was the one actually in use.
                ForEach(promptConfig.visiblePrompts) { prompt in
                    Button {
                        settings.selectedPromptId = prompt.id
                    } label: {
                        HStack {
                            Text(prompt.name)
                            if prompt.id == (settings.selectedPromptId ?? PromptConfiguration.defaultPromptId) {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack {
                    Text(selectedPromptName)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.1))
                )
            }
            .menuStyle(.borderlessButton)
            .disabled(!settings.aiEnabled)
        }
    }

    private var selectedPromptName: String {
        if !settings.aiEnabled {
            return "AI Disabled"
        }
        guard let promptId = settings.selectedPromptId else {
            return "Clean Up"
        }
        // Naming the default here when the lookup fails hides a stored id whose prompt
        // has been deleted, and with it the reason the AI pass has started failing.
        return promptConfig.prompt(withId: promptId)?.name ?? "Missing Prompt"
    }

    // MARK: - Quick Toggles

    private var quickToggles: some View {
        VStack(spacing: 4) {
            Toggle(isOn: Binding(
                get: { settings.aiEnabled },
                set: { settings.aiEnabled = $0 }
            )) {
                Label("AI Processing", systemImage: "brain")
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Toggle(isOn: Binding(
                get: { coordinator.skipAIOnce },
                set: { coordinator.skipAIOnce = $0 }
            )) {
                Label("Skip AI This Time", systemImage: "forward.fill")
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(!settings.aiEnabled)
        }
        .padding(.vertical, 4)
    }

    /// Open one of the app's windows and bring it to the front.
    ///
    /// A menu bar app is not the active application while its popover is showing, so
    /// `openWindow` on its own puts the new window behind whatever the user was
    /// looking at, and they have to go and find it.
    private func show(_ windowID: String) {
        openWindow(id: windowID)
        NSApp.activate()
    }

    // MARK: - Meeting Section

    /// Meeting mode is deliberately its own control rather than a variant of the
    /// record button: dictation delivers text and forgets it, a meeting is kept.
    private var meetingSection: some View {
        VStack(spacing: 4) {
            Button {
                if meetingRecorder.hasActiveMeeting {
                    Task { await meetingRecorder.stop(in: modelContext) }
                } else {
                    show(ScribeApp.meetingsWindowID)
                    Task { await meetingRecorder.start(in: modelContext) }
                }
            } label: {
                HStack {
                    Image(systemName: meetingRecorder.isRecording ? "stop.circle.fill" : "person.2.wave.2")
                        .foregroundStyle(meetingRecorder.isRecording ? .red : .primary)
                    Text(meetingButtonTitle)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)
            .disabled(transcriptionEngine.isBusy && !meetingRecorder.hasActiveMeeting)

            if meetingRecorder.hasActiveMeeting {
                Button {
                    Task {
                        if meetingRecorder.isPaused {
                            await meetingRecorder.resume()
                        } else {
                            await meetingRecorder.pause()
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: meetingRecorder.isPaused ? "play.circle" : "pause.circle")
                        Text(meetingRecorder.isPaused ? "Resume Meeting" : "Pause Meeting")
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
            }

            Button {
                show(ScribeApp.meetingsWindowID)
            } label: {
                HStack {
                    Image(systemName: "list.bullet.rectangle")
                    Text("Meetings...")
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)

            Button {
                show(ScribeApp.importWindowID)
            } label: {
                HStack {
                    Image(systemName: "waveform.badge.plus")
                    Text("Import Recording...")
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)

            Button {
                show(ScribeApp.historyWindowID)
            } label: {
                HStack {
                    Image(systemName: "clock.arrow.circlepath")
                    Text("Dictation History...")
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)
        }
    }

    private var meetingButtonTitle: String {
        switch meetingRecorder.state {
        case .idle: "Start Meeting"
        case .preparing: "Preparing..."
        case .recording: "Stop Meeting"
        case .paused: "Stop Meeting (Paused)"
        case .finishing: "Saving..."
        }
    }

    // MARK: - Footer Section

    private var footerSection: some View {
        VStack(spacing: 4) {
            SettingsLink {
                HStack {
                    Image(systemName: "gear")
                    Text("Settings...")
                    Spacer()
                    Text("⌘,")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)

            Divider()
                .padding(.vertical, 4)

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                HStack {
                    Image(systemName: "power")
                    Text("Quit")
                    Spacer()
                    Text("⌘Q")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Trigger Description

    /// What the user actually presses, so the menu never advertises a stale shortcut.
    private var triggerLabel: String {
        settings.useGlobeKey ? "🌐" : settings.hotkeyString
    }

    private var activationHint: String {
        settings.hotkeyActivationMode == .pushToTalk ? "Hold" : "Press"
    }

    // MARK: - Actions

    private func toggleRecording() async {
        await coordinator.toggle()
    }
}

// MARK: - Menu Bar Icon

struct MenuBarIcon: View {
    let isRecording: Bool
    let isProcessing: Bool

    var body: some View {
        Image(systemName: iconName)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(iconColor)
    }

    private var iconName: String {
        if isRecording {
            return "mic.fill"
        } else if isProcessing {
            return "brain"
        } else {
            return "mic"
        }
    }

    private var iconColor: Color {
        if isRecording {
            return .red
        } else if isProcessing {
            return .orange
        } else {
            return .primary
        }
    }
}

#Preview {
    let settings = AppSettings()
    let prompts = PromptConfiguration()
    let engine = TranscriptionEngine()
    let processor = AIProcessor(promptConfiguration: prompts)

    return MenuBarView()
        .environment(settings)
        .environment(prompts)
        .environment(engine)
        .environment(processor)
        .environment(RecordingCoordinator(engine: engine, aiProcessor: processor, settings: settings))
        .environment(MeetingRecorder(engine: engine, settings: settings, aiProcessor: processor))
        .modelContainer(for: [Meeting.self, Utterance.self, MeetingSpeaker.self], inMemory: true)
}

#endif
