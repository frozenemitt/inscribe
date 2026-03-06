import SwiftUI

#if os(macOS)

/// The main menu bar interface for the transcription tool
struct MenuBarView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(PromptConfiguration.self) private var promptConfig
    @Environment(TranscriptionEngine.self) private var transcriptionEngine
    @Environment(AIProcessor.self) private var aiProcessor
    @State private var skipAIThisTime = false

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
        if transcriptionEngine.isRecording {
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
            return "Press \(settings.hotkeyString) to start"
        }
    }

    // MARK: - Recording Button

    private var recordingButton: some View {
        Button {
            Task {
                await toggleRecording()
            }
        } label: {
            HStack {
                Image(systemName: transcriptionEngine.isRecording ? "stop.fill" : "record.circle")
                    .font(.title3)
                    .foregroundStyle(transcriptionEngine.isRecording ? .red : .primary)

                Text(transcriptionEngine.isRecording ? "Stop Recording" : "Start Recording")
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(settings.hotkeyString)
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
                .fill(transcriptionEngine.isRecording ? Color.red.opacity(0.1) : Color.clear)
        )
        .disabled(aiProcessor.isProcessing)
    }

    // MARK: - Prompt Section

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AI Prompt")
                .font(.caption)
                .foregroundStyle(.secondary)

            Menu {
                ForEach(promptConfig.visiblePrompts) { prompt in
                    Button {
                        settings.selectedPromptId = prompt.id
                    } label: {
                        HStack {
                            Text(prompt.name)
                            if prompt.id == settings.selectedPromptId {
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
        guard let promptId = settings.selectedPromptId,
              let prompt = promptConfig.prompt(withId: promptId) else {
            return "Clean Up"
        }
        return prompt.name
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

            Toggle(isOn: $skipAIThisTime) {
                Label("Skip AI This Time", systemImage: "forward.fill")
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(!settings.aiEnabled)
        }
        .padding(.vertical, 4)
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

    // MARK: - Actions

    private func toggleRecording() async {
        if transcriptionEngine.isRecording {
            await stopRecordingAndProcess()
        } else {
            await startRecording()
        }
    }

    private func startRecording() async {
        do {
            try await transcriptionEngine.startRecording()
        } catch {
            print("[MenuBarView] Failed to start recording: \(error)")
            // TODO: Show error notification
        }
    }

    private func stopRecordingAndProcess() async {
        do {
            // Stop recording and get transcript
            let transcript = try await transcriptionEngine.stopRecording()

            guard !transcript.isEmpty else {
                print("[MenuBarView] No transcript to process")
                return
            }

            // Process with AI if enabled
            var finalText = transcript
            if settings.aiEnabled && !skipAIThisTime {
                finalText = try await aiProcessor.process(
                    text: transcript,
                    promptId: settings.selectedPromptId
                )
            }

            // Copy to clipboard
            if settings.copyToClipboardAutomatically {
                ClipboardService.copy(finalText)
            }

            // Reset skip toggle
            skipAIThisTime = false

            // TODO: Play feedback sound
            // TODO: Show notification

        } catch {
            print("[MenuBarView] Error during stop/process: \(error)")
            // TODO: Show error notification
        }
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
    MenuBarView()
        .environment(AppSettings())
        .environment(PromptConfiguration())
        .environment(TranscriptionEngine())
        .environment(AIProcessor(promptConfiguration: PromptConfiguration()))
}

#endif
