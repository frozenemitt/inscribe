import SwiftUI
import AppIntents

#if os(macOS)
import AppKit

/// App delegate for macOS-specific initialization
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Called by ScribeApp to provide services for hotkey setup
    var onReady: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("[AppDelegate] App finished launching")
        onReady?()
    }
}
#endif

@main
struct ScribeApp: App {
    // MARK: - App Delegate

    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif

    // MARK: - Services

    @State private var settings = AppSettings()
    @State private var promptConfig = PromptConfiguration()
    @State private var transcriptionEngine = TranscriptionEngine()
    @State private var aiProcessor: AIProcessor

    #if os(macOS)
    @State private var hotkeyService = HotkeyService()
    @State private var hasSetupHotkey = false
    #endif

    // MARK: - Initialization

    init() {
        // Initialize AI processor with prompt config
        let prompts = PromptConfiguration()
        self._promptConfig = State(initialValue: prompts)
        self._aiProcessor = State(initialValue: AIProcessor(promptConfiguration: prompts))

        // Register App Intents shortcuts
        _ = InscribeShortcuts.self

        print("[ScribeApp] Initialized")

        #if os(macOS)
        // Wire up hotkey registration to fire at app launch, not on first menu click
        appDelegate.onReady = { [self] in
            setupHotkeyOnce()
        }
        #endif
    }

    // MARK: - Scene

    var body: some Scene {
        #if os(macOS)
        macOSScene
        #else
        iOSScene
        #endif
    }

    // MARK: - macOS Scene

    #if os(macOS)
    @SceneBuilder
    private var macOSScene: some Scene {
        // Menu bar app
        MenuBarExtra {
            MenuBarView()
                .environment(settings)
                .environment(promptConfig)
                .environment(transcriptionEngine)
                .environment(aiProcessor)
                .environment(hotkeyService)
        } label: {
            MenuBarIcon(
                isRecording: transcriptionEngine.isRecording,
                isProcessing: aiProcessor.isProcessing
            )
        }
        .menuBarExtraStyle(.window)

        // Settings window
        Settings {
            SettingsView()
                .environment(settings)
                .environment(promptConfig)
                .environment(hotkeyService)
                .windowResizeBehavior(.enabled)
        }
    }

    private func setupHotkeyOnce() {
        // Only setup once
        guard !hasSetupHotkey else { return }
        hasSetupHotkey = true

        // Register global hotkey callback
        hotkeyService.onHotkeyPressed = { [self] in
            Task { @MainActor in
                await toggleRecording()
            }
        }

        // Register the hotkey
        hotkeyService.registerHotkey(from: settings.hotkeyString)

        print("[ScribeApp] Hotkey registered: \(settings.hotkeyString), success: \(hotkeyService.isRegistered)")
        if let error = hotkeyService.lastError {
            print("[ScribeApp] Hotkey error: \(error)")
        }

        // Request authorization
        Task {
            _ = await transcriptionEngine.requestAuthorization()
        }

        print("[ScribeApp] macOS setup complete")
    }

    @MainActor
    private func toggleRecording() async {
        if transcriptionEngine.isRecording {
            await stopRecordingAndProcess()
        } else {
            await startRecording()
        }
    }

    @MainActor
    private func startRecording() async {
        // Play feedback sound
        AudioFeedbackService.shared.playIfEnabled(.recordingStarted, settings: settings)

        do {
            try await transcriptionEngine.startRecording()
            print("[ScribeApp] Recording started via hotkey")
        } catch {
            AudioFeedbackService.shared.playIfEnabled(.error, settings: settings)
            print("[ScribeApp] Failed to start recording: \(error)")
        }
    }

    @MainActor
    private func stopRecordingAndProcess() async {
        // Play stop sound
        AudioFeedbackService.shared.playIfEnabled(.recordingStopped, settings: settings)

        do {
            let transcript = try await transcriptionEngine.stopRecording()

            guard !transcript.isEmpty else {
                print("[ScribeApp] No transcript to process")
                return
            }

            var finalText = transcript
            if settings.aiEnabled {
                finalText = try await aiProcessor.process(
                    text: transcript,
                    promptId: settings.selectedPromptId
                )
            }

            if settings.copyToClipboardAutomatically {
                ClipboardService.copy(finalText)
            }

            // Play completion sound and show notification
            AudioFeedbackService.shared.playIfEnabled(.processingComplete, settings: settings)
            NotificationService.shared.showTranscriptionCompleteIfEnabled(
                characterCount: finalText.count,
                settings: settings
            )

            print("[ScribeApp] Transcription complete and copied to clipboard")
        } catch {
            AudioFeedbackService.shared.playIfEnabled(.error, settings: settings)
            NotificationService.shared.showError(error.localizedDescription)
            print("[ScribeApp] Error during stop/process: \(error)")
        }
    }
    #endif

    // MARK: - iOS Scene

    #if os(iOS)
    @StateObject private var liveActivityManager = LiveActivityManager.shared

    @SceneBuilder
    private var iOSScene: some Scene {
        WindowGroup {
            iOSMainView()
                .environment(settings)
                .environment(promptConfig)
                .environment(transcriptionEngine)
                .environment(aiProcessor)
                .environmentObject(liveActivityManager)
                .onAppear {
                    setupIOS()
                }
        }
    }

    private func setupIOS() {
        // Request authorization on launch
        Task {
            _ = await transcriptionEngine.requestAuthorization()
        }

        // Request notification authorization
        _ = NotificationService.shared

        print("[ScribeApp] iOS setup complete")
    }
    #endif
}

// MARK: - iOS Main View

#if os(iOS)
struct iOSMainView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(TranscriptionEngine.self) private var transcriptionEngine
    @Environment(AIProcessor.self) private var aiProcessor

    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                // Status icon
                Image(systemName: statusIcon)
                    .font(.system(size: 80))
                    .foregroundStyle(statusColor)
                    .symbolEffect(.pulse, options: .repeating, isActive: transcriptionEngine.isRecording)

                // Status text
                VStack(spacing: 8) {
                    Text(statusTitle)
                        .font(.title)
                        .fontWeight(.bold)

                    Text(statusSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                // Transcript preview
                if !transcriptionEngine.currentTranscript.isEmpty || !transcriptionEngine.volatileText.isEmpty {
                    ScrollView {
                        Text(transcriptionEngine.currentTranscript + transcriptionEngine.volatileText)
                            .font(.body)
                            .padding()
                    }
                    .frame(maxHeight: 200)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.secondary.opacity(0.1))
                    )
                    .padding(.horizontal)
                }

                Spacer()

                // Info text
                VStack(spacing: 8) {
                    Text("Use Shortcuts or Siri to start recording")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("\"Hey Siri, transcribe with Inscribe\"")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .italic()
                }
            }
            .padding()
            .navigationTitle("Inscribe")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gear")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
        }
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
            return .blue
        }
    }

    private var statusTitle: String {
        if transcriptionEngine.isRecording {
            return "Recording"
        } else if aiProcessor.isProcessing {
            return "Processing"
        } else {
            return "Ready"
        }
    }

    private var statusSubtitle: String {
        if transcriptionEngine.isRecording {
            return "Listening..."
        } else if aiProcessor.isProcessing {
            return "Applying AI processing..."
        } else {
            return "Use Shortcuts to start a transcription"
        }
    }
}
#endif

// MARK: - App Shortcuts

struct InscribeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: QuickTranscribeIntent(),
            phrases: [
                "Transcribe with \(.applicationName)",
                "Quick transcribe with \(.applicationName)",
                "Start transcribing with \(.applicationName)"
            ],
            shortTitle: "Quick Transcribe",
            systemImageName: "mic"
        )
    }
}
