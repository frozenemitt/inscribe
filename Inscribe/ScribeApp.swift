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

    /// Finish and save any meeting still recording. Returns false when there was none.
    ///
    /// A meeting's transcript, utterances and speakers live in memory until stop()
    /// writes them, and the recording's AVAudioFile is only closed there too. Quitting
    /// mid-meeting without this loses the transcript outright and leaves an .m4a with
    /// no moov atom — a file that exists, so the app offers to play it, and cannot be
    /// opened.
    var finishActiveMeeting: (@MainActor (@escaping () -> Void) -> Bool)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.notice("App finished launching")
        onReady?()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let finishActiveMeeting else { return .terminateNow }

        let needsSaving = finishActiveMeeting {
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }

        return needsSaving ? .terminateLater : .terminateNow
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

    /// One store for meetings and dictation history, shared by every scene.
    ///
    /// Built once here rather than by `.modelContainer(for:)` per scene, so the menu
    /// bar and the meetings window write to the same file rather than two. Static
    /// because App Intents are built by the system and cannot be handed the app's
    /// dependencies — without this a shortcut could not write to history at all.
    static let modelContainer: ModelContainer = {
        let log = Logger(subsystem: "com.inscribe.app", category: "Store")
        let schema = Schema(versionedSchema: MeetingSchemaV1.self)
        do {
            #if os(macOS)
            // A file of our own, never the default. The Mac app is not sandboxed, so the
            // default is the shared ~/Library/Application Support/default.store — a file
            // Apple's icloudmailagent also keeps its data in. Each of the two rebuilt it
            // in its own schema on launch and dropped the other's tables: every meeting
            // and dictation was lost, and every save after that failed and was retried
            // on the main thread until the hotkey lagged by seconds.
            let folder = URL.applicationSupportDirectory.appending(path: "Inscribe", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let config = ModelConfiguration(schema: schema, url: folder.appending(path: "Inscribe.store"))
            #else
            // Sandboxed, so the default location is already private to this app.
            let config = ModelConfiguration(schema: schema)
            #endif
            let container = try ModelContainer(
                for: schema,
                migrationPlan: MeetingMigrationPlan.self,
                configurations: [config]
            )
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
    @State private var hotkeyMonitor = GlobalHotkeyMonitor.shared
    #endif

    // MARK: - Initialization

    init() {
        // Before anything reads a preference: the app has changed bundle identifier,
        // and UserDefaults is keyed by it.
        PreferencesMigration.runIfNeeded()

        // Built here rather than inline so the coordinator can be handed the very
        // same instances the views observe.
        let settings = AppSettings()
        let prompts = PromptConfiguration()
        let engine = TranscriptionEngine.shared
        let processor = AIProcessor(promptConfiguration: prompts)

        let coordinator = RecordingCoordinator(engine: engine, aiProcessor: processor, settings: settings)
        let recorder = MeetingRecorder(engine: engine, settings: settings, aiProcessor: processor)

        self._settings = State(initialValue: settings)
        self._promptConfig = State(initialValue: prompts)
        self._transcriptionEngine = State(initialValue: engine)
        self._aiProcessor = State(initialValue: processor)
        self._coordinator = State(initialValue: coordinator)
        self._meetingRecorder = State(initialValue: recorder)

        // Register App Intents shortcuts
        _ = InscribeShortcuts.self

        Log.app.notice("Initialized")

        #if os(macOS)
        // Both closures hold the instances themselves, not `self`. Reading a `@State`
        // property outside a view gets no installed storage, and SwiftUI logs a warning
        // for every such read.
        //
        // Wire up hotkey registration to fire at app launch, not on first menu click.
        let launch = HotkeyLaunch(
            settings: settings,
            coordinator: coordinator,
            transcriptionEngine: engine,
            hotkeyMonitor: GlobalHotkeyMonitor.shared
        )
        appDelegate.onReady = { launch.run() }

        // Quitting mid-meeting must not discard it.
        appDelegate.finishActiveMeeting = { done in
            guard recorder.hasActiveMeeting else { return false }

            Log.app.notice("Quitting with a meeting open — saving it first")
            Task { @MainActor in
                await recorder.stop(in: Self.modelContainer.mainContext)
                done()
            }
            return true
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
                .modelContainer(Self.modelContainer)
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
                .environment(transcriptionEngine)
                .modelContainer(Self.modelContainer)
        }
        .defaultSize(width: 900, height: 600)

        Window("Import Recording", id: Self.importWindowID) {
            ImportRecordingView()
                .environment(settings)
                .modelContainer(Self.modelContainer)
        }
        .defaultSize(width: 560, height: 520)

        Window("Dictation History", id: Self.historyWindowID) {
            DictationHistoryView()
                .environment(settings)
                .modelContainer(Self.modelContainer)
        }
        .defaultSize(width: 620, height: 520)
    }

    static let meetingsWindowID = "meetings"
    static let historyWindowID = "history"
    static let importWindowID = "import"

    // MARK: - Launch Setup

    /// Installs the hotkey once the app has finished launching.
    @MainActor
    private struct HotkeyLaunch {
        let settings: AppSettings
        let coordinator: RecordingCoordinator
        let transcriptionEngine: TranscriptionEngine
        let hotkeyMonitor: GlobalHotkeyMonitor

        func run() {
            // No app Inscribe asks about may hold it up for long. The system's default
            // wait on an app that does not answer is several seconds, spent on the
            // main thread, and one of those calls runs as recording starts.
            TextInsertionService.limitAccessibilityWaits()

            // The coordinator keeps finished dictations, which needs the open store.
            coordinator.modelContext = ScribeApp.modelContainer.mainContext

            wireHotkeyCallbacks()
            armHotkey()

            Task {
                _ = await transcriptionEngine.requestAuthorization()
                // Resolve the locale and find the model now, so the first key press does
                // not pay for it while the user waits to speak.
                await transcriptionEngine.prepare()
            }

            Log.app.notice("macOS setup complete")
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
                Task { @MainActor in await coordinator.cancel() }
            }
            hotkeyMonitor.onAbandon = {
                Task { @MainActor in await coordinator.cancel(quietly: true) }
            }
            // Dictation only. The tap swallows Escape while this is true, so reporting a
            // meeting here would eat the key in whatever app the user is actually using,
            // for the whole length of the meeting — and cancel the meeting with it.
            Self.mirrorRecordingState(from: coordinator, into: hotkeyMonitor)
            hotkeyMonitor.onUndo = {
                Task { @MainActor in
                    guard let text = await TextInsertionService.undoLastInsertion() else { return }
                    AudioFeedbackService.shared.playIfEnabled(.recordingStopped, settings: settings)
                    Log.app.notice("Undid \(text.count) characters")
                }
            }
        }

        /// Keep the monitor's view of `isRecording` current.
        ///
        /// Pushed rather than pulled: the tap decides whether to swallow Escape on its own
        /// thread, and reaching back to the main actor for the answer is the wait that used
        /// to stall every keystroke on the machine. Re-arms itself after each change,
        /// because `withObservationTracking` fires once.
        @MainActor
        private static func mirrorRecordingState(
            from coordinator: RecordingCoordinator,
            into monitor: GlobalHotkeyMonitor
        ) {
            withObservationTracking {
                // From the moment a start begins, not only once it is recording: an
                // Escape pressed during the start should cancel it, not reach the app.
                monitor.isRecording = coordinator.isCancellable
            } onChange: {
                Task { @MainActor in mirrorRecordingState(from: coordinator, into: monitor) }
            }
        }

        /// Apply the current settings to the monitor and install the tap.
        private func armHotkey() {
            hotkeyMonitor.trigger = settings.hotkeyTrigger
            hotkeyMonitor.activationMode = settings.hotkeyActivationMode
            hotkeyMonitor.undoTrigger = settings.undoHotkeyTrigger

            let started = hotkeyMonitor.start()
            let trigger = settings.useGlobeKey ? "Globe" : settings.hotkeyString
            Log.app.notice("Hotkey \(trigger, privacy: .public) in \(settings.hotkeyActivationModeRaw, privacy: .public) mode, listening: \(started, privacy: .public)")

            if let error = hotkeyMonitor.lastError {
                Log.app.error("Hotkey error: \(error, privacy: .public)")
            }

            if !started { armWhenTrustArrives() }
        }

        /// Keep trying to install the tap until Accessibility trust shows up.
        ///
        /// `AXIsProcessTrusted()` answers false while the app is still finishing launch,
        /// even when access has been granted, so the single check above reads it as
        /// missing and the tap never gets built. Nothing retried: the menu bar said
        /// "Not listening", the key did nothing, and the only way out was to open
        /// Settings and nudge a hotkey field, because changing one calls `rearm()`.
        /// It also covers access granted minutes later, without a relaunch.
        private func armWhenTrustArrives() {
            Task { @MainActor in
                // Waiting for access has no deadline: it can be granted minutes later, and
                // asking costs nothing. Building the tap is different — a tap that refuses
                // to build while trusted is a real fault, and retrying it forever only
                // tears one down and rebuilds it every two seconds for the life of the app.
                // Three attempts, then say so and stop.
                // Asked here, once the check has failed after launch settled, rather
                // than at launch: the check can read false while launch is finishing,
                // and asking then showed the prompt to people who had already granted it.
                var askedForTrust = false
                while !AccessibilityPermission.isTrusted {
                    try? await Task.sleep(for: .seconds(2))
                    guard !hotkeyMonitor.isRunning else { return }
                    if !askedForTrust, !AccessibilityPermission.isTrusted {
                        askedForTrust = true
                        AccessibilityPermission.requestTrust()
                    }
                }

                for attempt in 1...3 {
                    guard !hotkeyMonitor.isRunning else { return }
                    if hotkeyMonitor.start() {
                        Log.app.notice("Accessibility arrived, hotkey now listening")
                        return
                    }
                    Log.app.error("Accessibility granted but the tap would not build, attempt \(attempt, privacy: .public) of 3")
                    try? await Task.sleep(for: .seconds(2))
                }

                Log.app.error("Giving up on the hotkey. Open Settings to try again.")
            }
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

        Log.app.notice("iOS setup complete")
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
