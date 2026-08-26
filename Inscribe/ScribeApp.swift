import SwiftUI
import AppIntents
import SwiftData
import os

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

    @State private var settings: AppSettings
    @State private var promptConfig: PromptConfiguration
    @State private var transcriptionEngine: TranscriptionEngine
    @State private var aiProcessor: AIProcessor
    @State private var coordinator: RecordingCoordinator
    @State private var meetingRecorder: MeetingRecorder

    /// One store for meetings, shared by every scene.
    ///
    /// Built once here rather than by `.modelContainer(for:)` per scene, so the menu
    /// bar and the meetings window write to the same file rather than two.
    private let modelContainer: ModelContainer = {
        let log = Logger(subsystem: "com.inscribe.app", category: "Store")
        let schema = Schema(versionedSchema: MeetingSchemaV1.self)
        do {
            let container = try ModelContainer(for: schema, migrationPlan: MeetingMigrationPlan.self)
            log.notice("Meeting store opened on disk")
            MeetingStoreStatus.shared.setPersistent(true)
            return container
        } catch {
            // Falling back to memory keeps dictation working, but every meeting is
            // lost on quit — so it is recorded and shown, never silent.
            log.error("Meeting store unavailable, falling back to memory: \(error, privacy: .public)")
            MeetingStoreStatus.shared.setPersistent(false, reason: error.localizedDescription)
            let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            return try! ModelContainer(for: schema, configurations: [config])
        }
    }()

    #if os(macOS)
    @State private var hotkeyMonitor = GlobalHotkeyMonitor()
    @State private var hasSetupHotkey = false
    #endif

    // MARK: - Initialization

    init() {
        // Built here rather than inline so the coordinator can be handed the very
        // same instances the views observe.
        let settings = AppSettings()
        let prompts = PromptConfiguration()
        let engine = TranscriptionEngine()
        let processor = AIProcessor(promptConfiguration: prompts)

        self._settings = State(initialValue: settings)
        self._promptConfig = State(initialValue: prompts)
        self._transcriptionEngine = State(initialValue: engine)
        self._aiProcessor = State(initialValue: processor)
        self._coordinator = State(initialValue: RecordingCoordinator(
            engine: engine,
            aiProcessor: processor,
            settings: settings
        ))
        self._meetingRecorder = State(initialValue: MeetingRecorder(
            engine: engine,
            settings: settings,
            aiProcessor: processor
        ))

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
                .environment(coordinator)
                .environment(hotkeyMonitor)
                .environment(meetingRecorder)
                .modelContainer(modelContainer)
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
                .environment(coordinator)
                .environment(hotkeyMonitor)
                .environment(SoundCatalog.shared)
                .windowResizeBehavior(.enabled)
        }

        // Meetings live in a real window: they are long documents to read and edit,
        // which a menu bar popover cannot hold.
        Window("Meetings", id: Self.meetingsWindowID) {
            MeetingsView()
                .environment(settings)
                .environment(meetingRecorder)
                .modelContainer(modelContainer)
        }
        .defaultSize(width: 900, height: 600)

        Window("Import Recording", id: Self.importWindowID) {
            ImportRecordingView()
                .environment(settings)
                .modelContainer(modelContainer)
        }
        .defaultSize(width: 560, height: 520)

        Window("Dictation History", id: Self.historyWindowID) {
            DictationHistoryView()
                .environment(settings)
                .modelContainer(modelContainer)
        }
        .defaultSize(width: 620, height: 520)
    }

    static let meetingsWindowID = "meetings"
    static let historyWindowID = "history"
    static let importWindowID = "import"

    // MARK: - Launch Setup

    private func setupHotkeyOnce() {
        guard !hasSetupHotkey else { return }
        hasSetupHotkey = true

        // Asking on first launch puts the prompt in front of the user while they are
        // still thinking about Inscribe. macOS shows it only once per app version.
        if !AccessibilityPermission.isTrusted {
            AccessibilityPermission.requestTrust()
        }

        // The coordinator keeps finished dictations, which needs the open store.
        coordinator.modelContext = modelContainer.mainContext

        wireHotkeyCallbacks()
        armHotkey()

        Task {
            _ = await transcriptionEngine.requestAuthorization()
        }

        print("[ScribeApp] macOS setup complete")
    }

    /// Point the monitor's edges at the coordinator.
    ///
    /// Push-to-talk uses the press and release edges; toggle uses only the press.
    /// `GlobalHotkeyMonitor` decides which callbacks fire, so both live here.
    private func wireHotkeyCallbacks() {
        hotkeyMonitor.onActivate = {
            Task { @MainActor in await coordinator.start() }
        }
        hotkeyMonitor.onDeactivate = {
            Task { @MainActor in await coordinator.stopAndProcess() }
        }
        hotkeyMonitor.onToggle = {
            Task { @MainActor in await coordinator.toggle() }
        }
        hotkeyMonitor.onCancel = {
            Task { @MainActor in coordinator.cancel() }
        }
        hotkeyMonitor.isRecordingProvider = {
            MainActor.assumeIsolated { transcriptionEngine.isRecording }
        }
        hotkeyMonitor.onUndo = {
            Task { @MainActor in
                guard let text = await TextInsertionService.undoLastInsertion() else { return }
                AudioFeedbackService.shared.playIfEnabled(.recordingStopped, settings: settings)
                print("[ScribeApp] Undid \(text.count) characters")
            }
        }
    }

    /// Apply the current settings to the monitor and install the tap.
    private func armHotkey() {
        hotkeyMonitor.trigger = settings.hotkeyTrigger
        hotkeyMonitor.activationMode = settings.hotkeyActivationMode
        hotkeyMonitor.undoTrigger = settings.undoHotkeyTrigger

        let started = hotkeyMonitor.start()
        let trigger = settings.useGlobeKey ? "Globe" : settings.hotkeyString
        print("[ScribeApp] Hotkey \(trigger) in \(settings.hotkeyActivationModeRaw) mode, listening: \(started)")

        if let error = hotkeyMonitor.lastError {
            print("[ScribeApp] Hotkey error: \(error)")
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
