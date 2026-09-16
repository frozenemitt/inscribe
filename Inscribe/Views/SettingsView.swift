import SwiftUI
import UniformTypeIdentifiers
import Combine

// MARK: - Settings View (Cross-Platform)

struct SettingsView: View {
    var body: some View {
        #if os(macOS)
        macOSSettings
        #else
        iOSSettings
        #endif
    }

    #if os(macOS)
    private var macOSSettings: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            SoundsSettingsView()
                .tabItem {
                    Label("Sounds", systemImage: "speaker.wave.2")
                }

            PromptsSettingsView()
                .tabItem {
                    Label("Prompts", systemImage: "text.bubble")
                }

            HotkeySettingsView()
                .tabItem {
                    Label("Hotkey", systemImage: "keyboard")
                }

            OutputSettingsView()
                .tabItem {
                    Label("Output", systemImage: "text.cursor")
                }

            DictationSettingsView()
                .tabItem {
                    Label("Dictation", systemImage: "waveform")
                }

            AppProfilesSettingsView()
                .tabItem {
                    Label("Apps", systemImage: "square.grid.2x2")
                }

            AboutSettingsView()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(minWidth: 520, idealWidth: 640, maxWidth: .infinity,
               minHeight: 420, idealHeight: 520, maxHeight: .infinity)
        .onAppear {
            // Bring Settings window to front — menu bar apps don't auto-activate
            NSApp.activate()
        }
    }
    #endif

    #if os(iOS)
    private var iOSSettings: some View {
        NavigationStack {
            List {
                NavigationLink {
                    GeneralSettingsView()
                } label: {
                    Label("General", systemImage: "gear")
                }

                NavigationLink {
                    PromptsSettingsView()
                } label: {
                    Label("Prompts", systemImage: "text.bubble")
                }

                NavigationLink {
                    AboutSettingsView()
                } label: {
                    Label("About", systemImage: "info.circle")
                }
            }
            .navigationTitle("Settings")
        }
    }
    #endif
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(PromptConfiguration.self) private var promptConfig
    #if os(macOS)
    @Environment(GlobalHotkeyMonitor.self) private var hotkeyMonitor
    #endif

    @State private var isConfirmingReset = false

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("AI Processing") {
                Toggle("Enable AI Processing", isOn: $settings.aiEnabled)

                if settings.aiEnabled {
                    Picker("Default Prompt", selection: $settings.selectedPromptId) {
                        Text("Clean Up (Default)").tag(nil as UUID?)
                        ForEach(promptConfig.prompts) { prompt in
                            Text(prompt.name).tag(prompt.id as UUID?)
                        }
                    }

                    Text("Uses Apple's on-device AI model. Your data never leaves your device.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Behavior") {
                #if os(iOS)
                // macOS decides this on the Output tab, where the insert-or-copy
                // choice lives; two controls for one behaviour is one too many.
                Toggle("Copy to clipboard automatically", isOn: $settings.copyToClipboardAutomatically)
                #endif
                Toggle("Play feedback sounds", isOn: $settings.playFeedbackSounds)
                Toggle("Play sound during AI processing", isOn: $settings.playProcessingIndicator)
            }

            Section("Dictation History") {
                Toggle("Keep recent dictations", isOn: $settings.keepDictationHistory)

                if settings.keepDictationHistory {
                    Stepper(value: $settings.dictationHistoryLimit, in: 10...500, step: 10) {
                        Text("Keep the last \(settings.dictationHistoryLimit)")
                            .monospacedDigit()
                    }
                }

                Text("Stores everything you dictate, in plain text on this Mac. Nothing is sent anywhere — but if you dictate anything you would not want written to disk, switch this off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Notifications") {
                Toggle("When a transcript is ready", isOn: $settings.showNotifications)
                Toggle("When something goes wrong", isOn: $settings.notifyOnError)

                Text("Errors are listed separately so silencing routine banners does not also hide the reason nothing appeared.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Reset to Defaults") {
                    isConfirmingReset = true
                }
                .confirmationDialog(
                    "Reset every setting to its default?",
                    isPresented: $isConfirmingReset,
                    titleVisibility: .visible
                ) {
                    Button("Reset Everything", role: .destructive) { resetToDefaults() }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("This also clears your word replacements, vocabulary hints, per-app settings and recorded hotkey. It cannot be undone.")
                }
            }
        }
        .formStyle(.grouped)
        #if os(iOS)
        .navigationTitle("General")
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func resetToDefaults() {
        settings.resetToDefaults()
        #if os(macOS)
        // The Hotkey tab re-arms on its own changes, but it is not on screen here —
        // without this the old combination keeps firing and the restored one does
        // nothing until the app is relaunched.
        hotkeyMonitor.trigger = settings.hotkeyTrigger
        hotkeyMonitor.activationMode = settings.hotkeyActivationMode
        hotkeyMonitor.undoTrigger = settings.undoHotkeyTrigger
        #endif
    }
}

// MARK: - Prompts Settings

struct PromptsSettingsView: View {
    @Environment(PromptConfiguration.self) private var promptConfig
    @Environment(AppSettings.self) private var settings

    @State private var selectedPromptId: UUID?
    @State private var isAddingPrompt = false

    var body: some View {
        #if os(macOS)
        macOSPromptsView
            .onAppear {
                if selectedPromptId == nil {
                    selectedPromptId = promptConfig.prompts.first?.id
                }
            }
        #else
        iOSPromptsView
        #endif
    }

    #if os(macOS)
    private var macOSPromptsView: some View {
        HSplitView {
            // Prompt list
            VStack(alignment: .leading, spacing: 0) {
                List(selection: $selectedPromptId) {
                    Section("Built-in Prompts") {
                        ForEach(promptConfig.builtInPromptsList) { prompt in
                            PromptRow(
                                prompt: prompt,
                                isSelected: selectedPromptId == prompt.id,
                                onToggleVisibility: {
                                    promptConfig.toggleVisibility(promptId: prompt.id)
                                }
                            )
                            .tag(prompt.id)
                        }
                    }

                    if !promptConfig.customPrompts.isEmpty {
                        Section("Custom Prompts") {
                            ForEach(promptConfig.customPrompts) { prompt in
                                PromptRow(
                                    prompt: prompt,
                                    isSelected: selectedPromptId == prompt.id,
                                    onToggleVisibility: {
                                        promptConfig.toggleVisibility(promptId: prompt.id)
                                    }
                                )
                                .tag(prompt.id)
                            }
                            .onDelete { indexSet in
                                deletePrompts(at: indexSet)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)

                Divider()

                HStack {
                    Button {
                        isAddingPrompt = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)

                    Button {
                        if let id = selectedPromptId {
                            deletePrompt(id: id)
                        }
                    } label: {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.borderless)
                    .disabled(selectedPromptId == nil || isBuiltIn(selectedPromptId))

                    Spacer()
                }
                .padding(8)
            }
            .frame(minWidth: 180, maxWidth: 220)

            // Prompt detail
            VStack {
                if let promptId = selectedPromptId,
                   let prompt = promptConfig.prompt(withId: promptId) {
                    PromptDetailView(
                        prompt: prompt,
                        canEdit: !prompt.isBuiltIn,
                        onSave: { updatedPrompt in
                            promptConfig.updatePrompt(updatedPrompt)
                        },
                        onDuplicate: { newPrompt in
                            promptConfig.addPrompt(newPrompt)
                            selectedPromptId = newPrompt.id
                        },
                        onSaveGenerationSettings: { temp, sampling, maxTokens in
                            promptConfig.updateGenerationSettings(
                                promptId: promptId,
                                temperature: temp,
                                samplingMode: sampling,
                                maxResponseTokens: maxTokens
                            )
                        }
                    )
                } else {
                    ContentUnavailableView(
                        "Select a Prompt",
                        systemImage: "text.bubble",
                        description: Text("Choose a prompt from the list to view or edit it.")
                    )
                }
            }
            .frame(minWidth: 280)
        }
        .sheet(isPresented: $isAddingPrompt) {
            AddPromptSheet { newPrompt in
                promptConfig.addPrompt(newPrompt)
                selectedPromptId = newPrompt.id
            }
        }
    }
    #endif

    #if os(iOS)
    private var iOSPromptsView: some View {
        List {
            Section("Built-in Prompts") {
                ForEach(promptConfig.builtInPromptsList) { prompt in
                    NavigationLink {
                        PromptDetailView(
                            prompt: prompt,
                            canEdit: false,
                            onSave: { _ in },
                            onDuplicate: { newPrompt in
                                promptConfig.addPrompt(newPrompt)
                            },
                            onToggleVisibility: {
                                promptConfig.toggleVisibility(promptId: prompt.id)
                            },
                            onSaveGenerationSettings: { temp, sampling, maxTokens in
                                promptConfig.updateGenerationSettings(
                                    promptId: prompt.id,
                                    temperature: temp,
                                    samplingMode: sampling,
                                    maxResponseTokens: maxTokens
                                )
                            }
                        )
                    } label: {
                        PromptRow(prompt: prompt, isSelected: false)
                    }
                }
            }

            Section("Custom Prompts") {
                ForEach(promptConfig.customPrompts) { prompt in
                    NavigationLink {
                        PromptDetailView(
                            prompt: prompt,
                            canEdit: true,
                            onSave: { updatedPrompt in
                                promptConfig.updatePrompt(updatedPrompt)
                            },
                            onDuplicate: { newPrompt in
                                promptConfig.addPrompt(newPrompt)
                            },
                            onToggleVisibility: {
                                promptConfig.toggleVisibility(promptId: prompt.id)
                            },
                            onSaveGenerationSettings: { temp, sampling, maxTokens in
                                promptConfig.updateGenerationSettings(
                                    promptId: prompt.id,
                                    temperature: temp,
                                    samplingMode: sampling,
                                    maxResponseTokens: maxTokens
                                )
                            }
                        )
                    } label: {
                        PromptRow(prompt: prompt, isSelected: false)
                    }
                }
                .onDelete { indexSet in
                    deletePrompts(at: indexSet)
                }
            }
        }
        .navigationTitle("Prompts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isAddingPrompt = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $isAddingPrompt) {
            NavigationStack {
                AddPromptSheet { newPrompt in
                    promptConfig.addPrompt(newPrompt)
                }
            }
        }
    }
    #endif

    private func isBuiltIn(_ id: UUID?) -> Bool {
        guard let id = id else { return true }
        return promptConfig.prompt(withId: id)?.isBuiltIn ?? true
    }

    private func deletePrompts(at indexSet: IndexSet) {
        // Resolved to ids up front: each deletion shrinks `customPrompts`, so the
        // later indices of a multi-row delete would land on the wrong prompts.
        let ids = indexSet.map { promptConfig.customPrompts[$0].id }
        for id in ids {
            deletePrompt(id: id)
        }
    }

    private func deletePrompt(id: UUID) {
        promptConfig.deletePrompt(withId: id)
        forgetDeletedPrompt(id)
        selectedPromptId = promptConfig.prompts.first?.id
    }

    /// Clear the settings still pointing at a prompt that no longer exists.
    ///
    /// A dangling id is not inert: the AI pass throws `promptNotFound` on every
    /// dictation from then on, and the menu bar goes on naming a prompt as if
    /// nothing had happened.
    private func forgetDeletedPrompt(_ id: UUID) {
        if settings.selectedPromptId == id {
            settings.selectedPromptId = nil
        }

        var profiles = settings.appProfiles
        let stale = profiles.filter { $0.value.promptId == id }.keys
        guard !stale.isEmpty else { return }
        for bundleID in stale {
            profiles[bundleID]?.promptId = nil
        }
        settings.appProfiles = profiles
    }
}

struct PromptRow: View {
    let prompt: Prompt
    let isSelected: Bool
    var onToggleVisibility: (() -> Void)?

    var body: some View {
        HStack {
            Image(systemName: prompt.isBuiltIn ? "sparkles" : "text.bubble")
                .foregroundStyle(isSelected ? .white : .secondary)

            Text(prompt.name)
                .lineLimit(1)

            Spacer()

            if let onToggleVisibility {
                Toggle("", isOn: Binding(
                    get: { prompt.isVisible },
                    set: { _ in onToggleVisibility() }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .help(prompt.isVisible ? "Visible in menu bar" : "Hidden from menu bar")
            } else if !prompt.isVisible {
                Image(systemName: "eye.slash")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct PromptDetailView: View {
    let prompt: Prompt
    let canEdit: Bool
    let onSave: (Prompt) -> Void
    var onDuplicate: ((Prompt) -> Void)?
    var onToggleVisibility: (() -> Void)?
    var onSaveGenerationSettings: ((Double, SamplingMode, Int?) -> Void)?

    // Prompt text state
    @State private var name: String
    @State private var systemPrompt: String
    @State private var userTemplate: String

    // Generation settings state
    @State private var temperature: Double
    @State private var samplingModeTag: String
    @State private var topPThreshold: Double
    @State private var topKValue: Int
    @State private var limitResponseTokens: Bool
    @State private var maxResponseTokens: Int

    init(
        prompt: Prompt,
        canEdit: Bool,
        onSave: @escaping (Prompt) -> Void,
        onDuplicate: ((Prompt) -> Void)? = nil,
        onToggleVisibility: (() -> Void)? = nil,
        onSaveGenerationSettings: ((Double, SamplingMode, Int?) -> Void)? = nil
    ) {
        self.prompt = prompt
        self.canEdit = canEdit
        self.onSave = onSave
        self.onDuplicate = onDuplicate
        self.onToggleVisibility = onToggleVisibility
        self.onSaveGenerationSettings = onSaveGenerationSettings
        self._name = State(initialValue: prompt.name)
        self._systemPrompt = State(initialValue: prompt.systemPrompt)
        self._userTemplate = State(initialValue: prompt.userTemplate)
        self._temperature = State(initialValue: prompt.temperature)
        self._samplingModeTag = State(initialValue: prompt.samplingMode.caseTag)
        // Extract associated values for sub-controls
        switch prompt.samplingMode {
        case .topP(let threshold):
            self._topPThreshold = State(initialValue: threshold)
            self._topKValue = State(initialValue: 10)
        case .topK(let k):
            self._topPThreshold = State(initialValue: 0.9)
            self._topKValue = State(initialValue: k)
        default:
            self._topPThreshold = State(initialValue: 0.9)
            self._topKValue = State(initialValue: 10)
        }
        self._limitResponseTokens = State(initialValue: prompt.maxResponseTokens != nil)
        self._maxResponseTokens = State(initialValue: prompt.maxResponseTokens ?? 500)
    }

    var body: some View {
        Form {
            #if os(iOS)
            if onToggleVisibility != nil {
                Section("Visibility") {
                    Toggle(isOn: Binding(
                        get: { prompt.isVisible },
                        set: { _ in onToggleVisibility?() }
                    )) {
                        Label("Show in menu bar dropdown", systemImage: prompt.isVisible ? "eye" : "eye.slash")
                    }
                }
            }
            #endif

            Section("Prompt Name") {
                TextField("Name", text: $name)
                    .disabled(!canEdit)
            }

            Section("System Prompt") {
                TextEditor(text: $systemPrompt)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 80)
                    .disabled(!canEdit)
            }

            Section("User Template") {
                TextEditor(text: $userTemplate)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 80)
                    .disabled(!canEdit)

                Text("Your transcription is automatically appended after these instructions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Generation settings — always editable, even for built-in prompts
            Section("Generation Settings") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Temperature")
                        Spacer()
                        Text(String(format: "%.1f", temperature))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $temperature, in: 0.0...2.0, step: 0.1)
                    Text(temperatureHint)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Picker("Sampling", selection: $samplingModeTag) {
                    Text("Automatic").tag("automatic")
                    Text("Greedy").tag("greedy")
                    Text("Top-P").tag("topP")
                    Text("Top-K").tag("topK")
                }
                .help("Automatic: default random sampling.\nGreedy: deterministic, always picks the most likely word.\nTop-P: samples from words within a cumulative probability threshold.\nTop-K: samples from the K most likely words.")

                Text(samplingHint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                if samplingModeTag == "topP" {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Probability Threshold")
                            Spacer()
                            Text(String(format: "%.2f", topPThreshold))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $topPThreshold, in: 0.1...1.0, step: 0.05)
                    }
                }

                if samplingModeTag == "topK" {
                    Stepper("Top K: \(topKValue)", value: $topKValue, in: 1...100)
                }

                Toggle("Limit response length", isOn: $limitResponseTokens)

                if limitResponseTokens {
                    Stepper("Max tokens: \(maxResponseTokens)", value: $maxResponseTokens, in: 50...2000, step: 50)
                }
            }

            if hasUnsavedChanges {
                Section {
                    Button("Save Changes") {
                        if canEdit && hasTextChanges {
                            let updated = Prompt(
                                id: prompt.id,
                                name: name,
                                systemPrompt: systemPrompt,
                                userTemplate: userTemplate,
                                isBuiltIn: false,
                                // Carried over: `updatePrompt` replaces the stored
                                // prompt wholesale, so anything left out is reset.
                                isVisible: prompt.isVisible,
                                temperature: temperature,
                                samplingMode: currentSamplingMode,
                                maxResponseTokens: limitResponseTokens ? maxResponseTokens : nil
                            )
                            onSave(updated)
                        }
                        if hasGenerationChanges {
                            onSaveGenerationSettings?(temperature, currentSamplingMode, limitResponseTokens ? maxResponseTokens : nil)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            Section {
                if let onDuplicate {
                    Button {
                        let duplicate = Prompt(
                            name: "\(name) Copy",
                            systemPrompt: systemPrompt,
                            userTemplate: userTemplate,
                            isBuiltIn: false,
                            temperature: temperature,
                            samplingMode: currentSamplingMode,
                            maxResponseTokens: limitResponseTokens ? maxResponseTokens : nil
                        )
                        onDuplicate(duplicate)
                    } label: {
                        Label("Duplicate as Custom Prompt", systemImage: "doc.on.doc")
                    }
                }
            }
        }
        .formStyle(.grouped)
        #if os(iOS)
        .navigationTitle(prompt.name)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // Keyed on the prompt's identity, not its value. Keyed on the value, any edit
        // to the stored prompt — toggling its visibility from its own row, say —
        // reloaded the editor and threw away whatever the user had typed but not saved.
        .onChange(of: prompt.id) { _, _ in
            let newPrompt = prompt
            name = newPrompt.name
            systemPrompt = newPrompt.systemPrompt
            userTemplate = newPrompt.userTemplate
            temperature = newPrompt.temperature
            samplingModeTag = newPrompt.samplingMode.caseTag
            switch newPrompt.samplingMode {
            case .topP(let t): topPThreshold = t
            case .topK(let k): topKValue = k
            default: break
            }
            limitResponseTokens = newPrompt.maxResponseTokens != nil
            maxResponseTokens = newPrompt.maxResponseTokens ?? 500
        }
    }

    /// Build a SamplingMode from the current UI state
    private var currentSamplingMode: SamplingMode {
        switch samplingModeTag {
        case "greedy": return .greedy
        case "topP": return .topP(topPThreshold)
        case "topK": return .topK(topKValue)
        default: return .automatic
        }
    }

    private var temperatureHint: String {
        if temperature < 0.3 { return "Very predictable" }
        if temperature < 0.7 { return "Balanced" }
        if temperature < 1.2 { return "Creative" }
        return "Highly creative"
    }

    private var samplingHint: String {
        switch samplingModeTag {
        case "greedy": return "Always picks the most likely word. Same input = same output."
        case "topP": return "Samples from the smallest set of words whose probabilities add up to the threshold."
        case "topK": return "Samples from the K most likely words. Lower K = more focused output."
        default: return "Default random sampling with temperature-based variation."
        }
    }

    private var hasUnsavedChanges: Bool {
        (canEdit && hasTextChanges) || hasGenerationChanges
    }

    private var hasTextChanges: Bool {
        name != prompt.name ||
        systemPrompt != prompt.systemPrompt ||
        userTemplate != prompt.userTemplate
    }

    private var hasGenerationChanges: Bool {
        temperature != prompt.temperature ||
        currentSamplingMode != prompt.samplingMode ||
        (limitResponseTokens ? maxResponseTokens : nil) != prompt.maxResponseTokens
    }
}

struct AddPromptSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var systemPrompt = "You are a helpful text processing assistant."
    @State private var userTemplate = ""
    @State private var temperature = 0.5
    @State private var samplingModeTag = "automatic"
    @State private var topPThreshold = 0.9
    @State private var topKValue = 10
    @State private var limitResponseTokens = false
    @State private var maxResponseTokens = 500

    let onAdd: (Prompt) -> Void

    private var currentSamplingMode: SamplingMode {
        switch samplingModeTag {
        case "greedy": return .greedy
        case "topP": return .topP(topPThreshold)
        case "topK": return .topK(topKValue)
        default: return .automatic
        }
    }

    private var samplingHint: String {
        switch samplingModeTag {
        case "greedy": return "Always picks the most likely word. Same input = same output."
        case "topP": return "Samples from the smallest set of words whose probabilities add up to the threshold."
        case "topK": return "Samples from the K most likely words. Lower K = more focused output."
        default: return "Default random sampling with temperature-based variation."
        }
    }

    var body: some View {
        Form {
            Section("Name") {
                TextField("Prompt name", text: $name)
            }

            Section("System Prompt") {
                TextEditor(text: $systemPrompt)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 80)
            }

            Section("User Template") {
                TextEditor(text: $userTemplate)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 80)

                Text("Your transcription is automatically appended after these instructions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Generation Settings") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Temperature")
                        Spacer()
                        Text(String(format: "%.1f", temperature))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $temperature, in: 0.0...2.0, step: 0.1)
                }

                Picker("Sampling", selection: $samplingModeTag) {
                    Text("Automatic").tag("automatic")
                    Text("Greedy").tag("greedy")
                    Text("Top-P").tag("topP")
                    Text("Top-K").tag("topK")
                }
                .help("Automatic: default random sampling.\nGreedy: deterministic, always picks the most likely word.\nTop-P: samples from words within a cumulative probability threshold.\nTop-K: samples from the K most likely words.")

                Text(samplingHint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                if samplingModeTag == "topP" {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Probability Threshold")
                            Spacer()
                            Text(String(format: "%.2f", topPThreshold))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $topPThreshold, in: 0.1...1.0, step: 0.05)
                    }
                }

                if samplingModeTag == "topK" {
                    Stepper("Top K: \(topKValue)", value: $topKValue, in: 1...100)
                }

                Toggle("Limit response length", isOn: $limitResponseTokens)

                if limitResponseTokens {
                    Stepper("Max tokens: \(maxResponseTokens)", value: $maxResponseTokens, in: 50...2000, step: 50)
                }
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
        .frame(minWidth: 450, minHeight: 500)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") {
                    let prompt = Prompt(
                        name: name,
                        systemPrompt: systemPrompt,
                        userTemplate: userTemplate,
                        temperature: temperature,
                        samplingMode: currentSamplingMode,
                        maxResponseTokens: limitResponseTokens ? maxResponseTokens : nil
                    )
                    onAdd(prompt)
                    dismiss()
                }
                .disabled(name.isEmpty)
            }
        }
        #else
        .navigationTitle("New Prompt")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") {
                    let prompt = Prompt(
                        name: name,
                        systemPrompt: systemPrompt,
                        userTemplate: userTemplate,
                        temperature: temperature,
                        samplingMode: currentSamplingMode,
                        maxResponseTokens: limitResponseTokens ? maxResponseTokens : nil
                    )
                    onAdd(prompt)
                    dismiss()
                }
                .disabled(name.isEmpty)
            }
        }
        #endif
    }
}

// MARK: - Sounds Settings (macOS only)

#if os(macOS)
struct SoundsSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(SoundCatalog.self) private var soundCatalog

    @State private var importError: String?

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Feedback Sounds") {
                SoundPickerRow(
                    label: "Recording Started",
                    selection: $settings.startSoundName,
                    sounds: soundCatalog.allSounds
                )
                SoundPickerRow(
                    label: "Recording Stopped",
                    selection: $settings.stopSoundName,
                    sounds: soundCatalog.allSounds
                )
                SoundPickerRow(
                    label: "Processing Complete",
                    selection: $settings.completeSoundName,
                    sounds: soundCatalog.allSounds
                )
                SoundPickerRow(
                    label: "Error",
                    selection: $settings.errorSoundName,
                    sounds: soundCatalog.allSounds
                )
            }

            Section("Processing Indicator") {
                SoundPickerRow(
                    label: "Processing Loop",
                    selection: $settings.processingSoundName,
                    sounds: soundCatalog.allSounds
                )
            }

            Section("Custom Sounds") {
                if soundCatalog.customSounds.isEmpty {
                    Text("No custom sounds imported yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(soundCatalog.customSounds) { sound in
                        HStack {
                            Text(sound.displayName)

                            Spacer()

                            Button {
                                SoundCatalog.shared.preview(sound.id)
                            } label: {
                                Image(systemName: "speaker.wave.2")
                            }
                            .buttonStyle(.borderless)

                            Button(role: .destructive) {
                                deleteSound(sound.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }

                Button("Import Sound File...") {
                    importSoundFile()
                }

                if let importError {
                    Text(importError)
                        .foregroundStyle(.red)
                        .font(.caption)
                }

                Text("Supported formats: AIFF, WAV, MP3, CAF, M4A")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func importSoundFile() {
        let panel = NSOpenPanel()
        panel.title = "Import Sound File"
        panel.allowedContentTypes = [.aiff, .wav, .mp3, .audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try soundCatalog.importSound(from: url)
            importError = nil
        } catch {
            importError = "Failed to import: \(error.localizedDescription)"
        }
    }

    private func deleteSound(_ id: String) {
        do {
            // Reset any settings that reference this sound back to default
            if settings.startSoundName == id { settings.startSoundName = "Morse" }
            if settings.stopSoundName == id { settings.stopSoundName = "Pop" }
            if settings.completeSoundName == id { settings.completeSoundName = "Glass" }
            if settings.errorSoundName == id { settings.errorSoundName = "Basso" }
            if settings.processingSoundName == id { settings.processingSoundName = "Bottle" }

            try soundCatalog.deleteCustomSound(id: id)
        } catch {
            importError = "Failed to delete: \(error.localizedDescription)"
        }
    }
}

struct SoundPickerRow: View {
    let label: String
    @Binding var selection: String
    let sounds: [SoundCatalog.SoundItem]

    var body: some View {
        HStack {
            Picker(label, selection: $selection) {
                ForEach(sounds) { sound in
                    Text(sound.displayName).tag(sound.id)
                }
            }

            Button {
                SoundCatalog.shared.preview(selection)
            } label: {
                Image(systemName: "speaker.wave.2")
            }
            .buttonStyle(.borderless)
            .disabled(selection == SoundCatalog.noneID)
        }
    }
}
#endif

// MARK: - Hotkey Settings (macOS only)

#if os(macOS)
struct HotkeySettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(GlobalHotkeyMonitor.self) private var hotkeyMonitor

    @State private var isRecordingHotkey = false
    @State private var captureError: String?
    @State private var isTrusted = AccessibilityPermission.isTrusted

    /// Re-check trust while the window is open — the user grants it in System Settings,
    /// and macOS sends no notification when they do.
    private let trustPoll = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        @Bindable var settings = settings

        Form {
            accessibilitySection

            Section("Activation") {
                Picker("When the key is pressed", selection: $settings.hotkeyActivationModeRaw) {
                    ForEach(HotkeyActivationMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
            }

            Section("Trigger Key") {
                Toggle("Use the Globe (🌐) key", isOn: $settings.useGlobeKey)

                if settings.useGlobeKey {
                    Text("Set System Settings → Keyboard → \"Press 🌐 to\" to *Do Nothing*, or macOS will also switch your input source every time you dictate.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("Open Keyboard Settings") {
                        NSWorkspace.shared.open(
                            URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!
                        )
                    }
                    .buttonStyle(.link)
                } else {
                    customHotkeyRow
                }
            }

            Section("Undo") {
                Toggle("Enable an undo shortcut", isOn: $settings.undoHotkeyEnabled)

                if settings.undoHotkeyEnabled {
                    LabeledContent("Shortcut") {
                        Text(settings.undoHotkeyString)
                            .font(.system(.body, design: .monospaced))
                    }

                    Text("Takes back the last text Inscribe typed, and puts it on your clipboard. Sends the receiving app its own Undo, and only within two minutes — after that it would throw away unrelated work.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Status") {
                if hotkeyMonitor.isRunning {
                    Label("Listening for \(triggerDescription)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if let error = hotkeyMonitor.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                } else {
                    Label("Not listening", systemImage: "circle.dashed")
                        .foregroundStyle(.secondary)
                }

                Text("Press Escape while recording to discard it without producing text.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onReceive(trustPoll) { _ in
            let current = AccessibilityPermission.isTrusted
            guard current != isTrusted else { return }
            isTrusted = current
            // Trust just arrived — the tap could not have been created before now.
            if current, !hotkeyMonitor.isRunning {
                hotkeyMonitor.start()
            }
        }
        .onChange(of: isRecordingHotkey) { _, recording in
            if recording { startCapturing() } else { hotkeyMonitor.endCapture() }
        }
        .onChange(of: settings.useGlobeKey) { _, _ in rearm() }
        .onChange(of: settings.hotkeyString) { _, _ in rearm() }
        .onChange(of: settings.hotkeyActivationModeRaw) { _, _ in rearm() }
        .onChange(of: settings.undoHotkeyEnabled) { _, _ in rearm() }
        .onDisappear {
            // Capture swallows every keystroke on the machine, so it must never
            // outlive the screen that turned it on.
            hotkeyMonitor.endCapture()
            isRecordingHotkey = false
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var accessibilitySection: some View {
        if !isTrusted {
            Section {
                Label("Inscribe needs Accessibility access", systemImage: "lock.fill")
                    .foregroundStyle(.orange)

                Text("The hotkey and typing into other apps both go through macOS Accessibility. Nothing works until you grant it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Grant Access") {
                        AccessibilityPermission.requestTrust()
                    }
                    Button("Open System Settings") {
                        AccessibilityPermission.openSystemSettings()
                    }
                    .buttonStyle(.link)
                }
            }
        }
    }

    private var customHotkeyRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Shortcut")
                Spacer()
                if isRecordingHotkey {
                    Text("Press new hotkey...")
                        .foregroundStyle(.orange)
                } else {
                    Text(settings.hotkeyString)
                        .font(.system(.body, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.secondary.opacity(0.2))
                        )
                }
            }

            Button(isRecordingHotkey ? "Cancel" : "Record New Hotkey") {
                isRecordingHotkey.toggle()
            }

            if let captureError {
                Text(captureError)
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text("Use at least two of ⌃, ⌥ and ⌘, so the shortcut cannot swallow an everyday one like ⌘W. Escape cancels.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var triggerDescription: String {
        settings.useGlobeKey ? "the Globe key" : settings.hotkeyString
    }

    // MARK: - Hotkey Recording

    /// Listen for the combination the user wants, through the tap that is already
    /// watching the keyboard.
    ///
    /// The tap sees keystrokes wherever they are typed, so this no longer depends on
    /// the settings window holding keyboard focus — which is what a menu bar app
    /// cannot promise, and why the old local monitor caught nothing.
    private func startCapturing() {
        captureError = nil

        hotkeyMonitor.beginCapture { keyCode, modifiers in
            if keyCode == 53 {  // Escape
                isRecordingHotkey = false
                return
            }

            guard let combination = AppSettings.hotkeyString(
                forKeyCode: keyCode,
                modifiers: modifiers
            ) else {
                // Stay armed and say why, rather than swallowing the keystroke and
                // leaving the user pressing keys at a screen that never answers.
                captureError = "That one cannot be a hotkey. Use a letter, number or punctuation key with at least two of ⌃, ⌥ and ⌘."
                return
            }

            settings.hotkeyString = combination
            isRecordingHotkey = false
        }
    }

    /// Push the current settings into the running tap.
    private func rearm() {
        hotkeyMonitor.trigger = settings.hotkeyTrigger
        hotkeyMonitor.activationMode = settings.hotkeyActivationMode
        hotkeyMonitor.undoTrigger = settings.undoHotkeyTrigger
        if !hotkeyMonitor.isRunning, AccessibilityPermission.isTrusted {
            hotkeyMonitor.start()
        }
    }

}
#endif

// MARK: - Output Settings (macOS only)

#if os(macOS)
struct OutputSettingsView: View {
    /// One labelled slider with its value beside it. Two of these read as a pair.
    private func solidityRow(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label)
                .frame(width: 96, alignment: .leading)
            Slider(value: value, in: 0.25...1)
            Text(value.wrappedValue.formatted(.percent.precision(.fractionLength(0))))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }

    @Environment(AppSettings.self) private var settings
    @Environment(RecordingCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Where text goes") {
                Picker("After transcribing", selection: $settings.outputModeRaw) {
                    ForEach(OutputMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)

                if settings.outputMode == .smartInsert {
                    Text("Inscribe checks what has keyboard focus. A text field gets the text typed straight in; anything else falls back to the clipboard.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if settings.outputMode == .smartInsert {
                Section("Typing") {
                    Toggle("Restore my previous clipboard afterwards", isOn: $settings.restoreClipboardAfterPaste)

                    Toggle("Press Return after typing", isOn: $settings.autoSubmitAfterInsert)

                    if settings.autoSubmitAfterInsert {
                        Toggle("Use Shift+Return instead", isOn: $settings.useShiftReturnAfterInsert)
                            .padding(.leading, 20)

                        Text(settings.useShiftReturnAfterInsert
                             ? "Starts a new line and leaves the message unsent — for chat apps where Return would send it."
                             : "Sends the message in chat apps, and runs the search in search fields.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("While Speaking") {
                Toggle("Show the words as you say them", isOn: $settings.showDictationOverlay)

                Text("Floats a panel above other windows while you hold the key, so you can see the dictation landing rather than trusting a sound. Drag it anywhere; it comes back where you left it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if settings.showDictationOverlay {
                    solidityRow("Background", value: $settings.overlayOpacity)
                    solidityRow("Text and band", value: $settings.overlayContentOpacity)

                    Text("Two separate dials. The background is glass — turn it down to read the window underneath through it. The text and band sit on top and keep their own setting, so a pane you can see straight through can still carry words you can read.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("Move it back to the bottom") {
                        coordinator.resetOverlayPosition()
                    }
                }

                Toggle("Show the microphone during meetings", isOn: $settings.showMeetingIndicator)

                Text("A small panel with the same band, so an hour-long meeting shows it is still hearing the room rather than only that it is open. Drag it anywhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Context") {
                Toggle("Let the AI see what is already in the field", isOn: $settings.useSurroundingContext)

                Text("Reads the text around your cursor and gives it to the AI as background, so a dictated reply matches the thread it belongs to. It is marked as context to read, not text to rewrite. Uses the Accessibility access Inscribe already has, and never leaves your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Recording") {
                LabeledContent("Maximum length") {
                    HStack {
                        Stepper(
                            value: $settings.maxRecordingSeconds,
                            in: 30...3600,
                            step: 30
                        ) {
                            Text(durationLabel)
                                .monospacedDigit()
                        }
                    }
                }
                Text("Recording stops on its own at this point, so a stuck hotkey cannot record forever.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var durationLabel: String {
        let seconds = settings.maxRecordingSeconds
        let minutes = seconds / 60
        let remainder = seconds % 60
        if remainder == 0 { return "\(minutes) min" }
        return "\(minutes) min \(remainder) s"
    }
}
#endif

// MARK: - About Settings

struct AboutSettingsView: View {
    /// This run's own log, so a dictation that went wrong can be explained without
    /// anyone opening a terminal.
    @ViewBuilder
    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 8) {
            if entries.isEmpty {
                Text("Nothing recorded yet this run. Dictate once and come back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(entries.reversed()) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(entry.date, format: .dateTime.hour().minute().second())
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)

                                Text(entry.category)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 72, alignment: .leading)

                                Text(entry.message)
                                    .font(.caption2)
                                    .foregroundStyle(entry.isProblem ? Color.orange : .primary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 220)
            }

            HStack {
                Button("Refresh") { reload() }
                Button("Copy") {
                    ClipboardService.copy(Diagnostics.asText(entries))
                }
                .disabled(entries.isEmpty)
            }

            Text("Only this run, and only Inscribe. Anything you wrote or said is redacted by the system before it gets here.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    private func reload() {
        entries = (try? Diagnostics.recent()) ?? []
    }

    @State private var entries: [Diagnostics.Entry] = []
    @State private var showingDiagnostics = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "mic.fill")
                .font(.system(size: 60))
                .foregroundStyle(.blue)

            Text("Inscribe")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Background Voice Transcription")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text("Version 1.0.0")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Divider()
                .frame(width: 200)

            DisclosureGroup(isExpanded: $showingDiagnostics) {
                diagnostics
            } label: {
                Label("What Inscribe has been doing", systemImage: "stethoscope")
                    .font(.subheadline)
            }
            .frame(maxWidth: 520)
            .onChange(of: showingDiagnostics) { _, shown in
                if shown { reload() }
            }

            Divider()
                .frame(width: 200)

            VStack(spacing: 8) {
                Text("Uses on-device AI for transcription and text processing.")
                Text("Your voice data never leaves your device.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)

            Spacer()
        }
        .padding(40)
        #if os(iOS)
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Preview

#Preview {
    SettingsView()
        .environment(AppSettings())
        .environment(PromptConfiguration())
        #if os(macOS)
        .environment(GlobalHotkeyMonitor())
        .environment(SoundCatalog.shared)
        #endif
}

// MARK: - Dictation Settings (macOS only)

#if os(macOS)
struct DictationSettingsView: View {
    @Environment(AppSettings.self) private var settings

    @State private var devices: [AudioInputDevice] = []
    @State private var systemDefaultName = ""
    @State private var vocabularyText = ""
    @State private var replacements: [ReplacementRow] = []

    /// One editable row. Carries its own identity so SwiftUI does not reshuffle
    /// text fields as the user types a key that collides with another row.
    struct ReplacementRow: Identifiable, Equatable {
        let id = UUID()
        var spoken: String
        var written: String
    }

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Microphone") {
                Picker("Record from", selection: $settings.inputDeviceUID) {
                    Text("System Default (\(systemDefaultName))")
                        .tag(AudioInputDevice.systemDefaultUID)
                    ForEach(devices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }

                if settings.inputDeviceUID != AudioInputDevice.systemDefaultUID,
                   !devices.contains(where: { $0.uid == settings.inputDeviceUID }) {
                    Label("That device is not connected — recording falls back to the system default.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Meetings") {
                MeetingAudioSection()
            }

            Section("Vocabulary") {
                Text("Names and jargon the recognizer should expect, one per line. This steers what it listens for, so it beats correcting the same word every time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: $vocabularyText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 90)
                    .onChange(of: vocabularyText) { _, text in
                        settings.vocabularyHints = text
                            .split(separator: "\n")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                    }
            }

            Section("Speaker Models") {
                DiarizationModelsSection()
            }

            Section("Word Replacements") {
                Text("Applied after transcription, whole words only and ignoring case — so a rule for \"vox\" leaves \"voxel\" alone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach($replacements) { $row in
                    HStack {
                        TextField("heard", text: $row.spoken)
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)
                        TextField("written", text: $row.written)
                        Button {
                            replacements.removeAll { $0.id == row.id }
                            commitReplacements()
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                    }
                    .onChange(of: row) { _, _ in commitReplacements() }
                }

                Button {
                    replacements.append(ReplacementRow(spoken: "", written: ""))
                } label: {
                    Label("Add Replacement", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
    }

    private func load() {
        devices = AudioDeviceCatalog.inputDevices()
        systemDefaultName = AudioDeviceCatalog.systemDefaultName()
        vocabularyText = settings.vocabularyHints.joined(separator: "\n")
        replacements = settings.wordReplacements
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { ReplacementRow(spoken: $0.key, written: $0.value) }
    }

    /// Rebuild the stored dictionary from the rows, dropping half-finished ones.
    private func commitReplacements() {
        var result: [String: String] = [:]
        for row in replacements {
            let spoken = row.spoken.trimmingCharacters(in: .whitespaces)
            let written = row.written.trimmingCharacters(in: .whitespaces)
            guard !spoken.isEmpty, !written.isEmpty else { continue }
            result[spoken] = written
        }
        settings.wordReplacements = result
    }
}
#endif

// MARK: - Per-App Profiles (macOS only)

#if os(macOS)
struct AppProfilesSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(PromptConfiguration.self) private var promptConfig

    @State private var profiles: [AppProfile] = []
    @State private var isPickingApp = false

    var body: some View {
        Form {
            Section {
                Text("Override the prompt or output for particular apps. The app that was frontmost when you started talking decides which profile runs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if profiles.isEmpty {
                Section {
                    Text("No profiles yet.")
                        .foregroundStyle(.secondary)
                }
            }

            ForEach($profiles) { $profile in
                Section {
                    Toggle(profile.appName, isOn: $profile.isEnabled)
                        .font(.headline)
                        .onChange(of: profile.isEnabled) { _, _ in commit() }

                    Picker("Prompt", selection: Binding(
                        get: { profile.promptId },
                        set: { profile.promptId = $0; commit() }
                    )) {
                        Text("Use the default").tag(nil as UUID?)
                        // Every prompt, not just the visible ones: hidden means hidden
                        // from the menu bar dropdown, and a profile already pointing at
                        // one would otherwise show an empty picker.
                        ForEach(promptConfig.prompts) { prompt in
                            Text(prompt.name).tag(prompt.id as UUID?)
                        }
                    }
                    .disabled(!profile.isEnabled)

                    Picker("Output", selection: Binding(
                        get: { profile.outputModeRaw },
                        set: { profile.outputModeRaw = $0; commit() }
                    )) {
                        Text("Use the default").tag(nil as String?)
                        ForEach(OutputMode.allCases) { mode in
                            Text(mode.displayName).tag(mode.rawValue as String?)
                        }
                    }
                    .disabled(!profile.isEnabled)

                    Picker("Press Return after typing", selection: Binding(
                        get: { profile.autoSubmit },
                        set: { profile.autoSubmit = $0; commit() }
                    )) {
                        Text("Use the default").tag(nil as Bool?)
                        Text("Yes").tag(true as Bool?)
                        Text("No").tag(false as Bool?)
                    }
                    .disabled(!profile.isEnabled)

                    Button("Remove Profile", role: .destructive) {
                        profiles.removeAll { $0.id == profile.id }
                        commit()
                    }
                    .buttonStyle(.borderless)
                }
            }

            Section {
                Button {
                    isPickingApp = true
                } label: {
                    Label("Add App", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
        .sheet(isPresented: $isPickingApp) {
            RunningAppPicker { app in
                add(app)
                isPickingApp = false
            } onCancel: {
                isPickingApp = false
            }
        }
    }

    private func load() {
        profiles = settings.appProfiles.values
            .sorted { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
    }

    private func commit() {
        settings.appProfiles = Dictionary(
            uniqueKeysWithValues: profiles.map { ($0.bundleIdentifier, $0) }
        )
    }

    private func add(_ app: NSRunningApplication) {
        guard let bundleID = app.bundleIdentifier else { return }
        guard !profiles.contains(where: { $0.bundleIdentifier == bundleID }) else { return }

        profiles.append(AppProfile(
            bundleIdentifier: bundleID,
            appName: app.localizedName ?? bundleID,
            promptId: nil,
            outputModeRaw: nil,
            autoSubmit: nil
        ))
        profiles.sort { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
        commit()
    }
}

/// Pick from the apps currently running, so the user never types a bundle identifier.
struct RunningAppPicker: View {
    let onPick: (NSRunningApplication) -> Void
    let onCancel: () -> Void

    private var apps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
            .sorted {
                ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Choose an App")
                .font(.headline)
                .padding()

            List(apps, id: \.processIdentifier) { app in
                Button {
                    onPick(app)
                } label: {
                    HStack {
                        if let icon = app.icon {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 20, height: 20)
                        }
                        Text(app.localizedName ?? app.bundleIdentifier ?? "Unknown")
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .frame(width: 360, height: 420)
    }
}
#endif

// MARK: - Diarization Model Management (macOS only)

#if os(macOS)
/// Status and updates for the CoreML speaker models.
///
/// FluidAudio downloads these once and never looks again — its only test is whether
/// the file exists, so an install keeps whatever the repository held that day forever.
/// This is the missing half: compare the recorded revision against the published head,
/// and replace on request.
struct DiarizationModelsSection: View {

    @State private var isInstalled = false
    @State private var sizeLabel = ""
    @State private var installedAt: Date?
    @State private var installedRevision: String?

    @State private var isChecking = false
    @State private var isUpdating = false
    @State private var isInstalling = false
    @State private var installError: String?
    @State private var checkResult: CheckResult?

    @State private var unusedFolders: [(name: String, size: Int64)] = []

    enum CheckResult: Equatable {
        case upToDate(Date?)
        case updateAvailable(Date?, changedFiles: Int)
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            status

            if isInstalled {
                HStack(spacing: 12) {
                    Button {
                        check()
                    } label: {
                        if isChecking {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Checking...")
                            }
                        } else {
                            Text("Check for Updates")
                        }
                    }
                    .disabled(isChecking || isUpdating)

                    if case .updateAvailable = checkResult {
                        Button(isUpdating ? "Updating..." : "Update Now") { update() }
                            .disabled(isUpdating)
                    } else {
                        // Always reachable: a check that reports a problem must leave
                        // the user something to press.
                        Button(isUpdating ? "Removing..." : "Re-download Models") { update() }
                            .disabled(isChecking || isUpdating)
                    }
                }

                if let checkResult {
                    resultLabel(checkResult)
                }

                Text("Checking verifies every installed file against the content hash HuggingFace publishes — SHA-256 for model weights, git blob hashes for the rest. No audio or transcript leaves your Mac; it reads public metadata only. Re-downloading removes the local copies so the next meeting fetches them fresh.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !isInstalled {
                Button(isInstalling ? "Installing..." : "Install Models") { install() }
                    .disabled(isInstalling)

                if let installError {
                    Text(installError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            if !unusedFolders.isEmpty {
                Divider()
                unusedModels
            }
        }
        .onAppear(perform: refresh)
    }

    // MARK: Sections

    @ViewBuilder
    private var status: some View {
        if isInstalled {
            LabeledContent("Installed") {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(sizeLabel)
                    if let installedAt {
                        Text(installedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let installedRevision {
                        Text(installedRevision.prefix(7))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } else {
            Label("Not installed. Meetings record and transcribe without them; installing adds speaker labels, and downloads about 13 MB from HuggingFace.",
                  systemImage: "arrow.down.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func resultLabel(_ result: CheckResult) -> some View {
        switch result {
        case .upToDate(let date):
            Label(
                date.map { "Verified — contents match the models published \($0.formatted(date: .abbreviated, time: .omitted))" }
                    ?? "Verified — contents match the published models",
                systemImage: "checkmark.seal.fill"
            )
            .font(.caption)
            .foregroundStyle(.green)

        case .updateAvailable(let date, let changed):
            Label(
                date.map { "\(changed) file\(changed == 1 ? "" : "s") no longer match — published \($0.formatted(date: .abbreviated, time: .omitted))" }
                    ?? "\(changed) file\(changed == 1 ? "" : "s") do not match the published models",
                systemImage: "arrow.down.circle.fill"
            )
            .font(.caption)
            .foregroundStyle(.orange)

        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private var unusedModels: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Other FluidAudio Models")
                .font(.caption.bold())

            Text("FluidAudio shares one cache across every model it offers. Inscribe uses only the speaker models — Apple's SpeechTranscriber does the transcribing — so these are taking space nothing reads.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(unusedFolders, id: \.name) { folder in
                HStack {
                    Text(folder.name)
                        .font(.caption)
                    Spacer()
                    Text(DiarizationModelStore.formatted(bytes: folder.size))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button("Remove Unused Models (\(DiarizationModelStore.formatted(bytes: unusedFolders.reduce(0) { $0 + $1.size })))") {
                try? DiarizationModelStore.removeUnusedModels()
                refresh()
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }

    // MARK: Actions

    private func refresh() {
        isInstalled = DiarizationModelStore.isInstalled
        sizeLabel = DiarizationModelStore.formatted(bytes: DiarizationModelStore.sizeOnDisk)
        installedAt = DiarizationModelStore.installedAt
        installedRevision = DiarizationModelStore.installedRevision
        unusedFolders = DiarizationModelStore.unusedModelFolders()
    }

    /// Download the models, which is the only moment Inscribe fetches them.
    ///
    /// Recording never does this: a meeting that reached the network would make an
    /// offline app dependent on a connection at the worst possible moment.
    private func install() {
        isInstalling = true
        installError = nil

        Task {
            do {
                try await DiarizationModelStore.install()
                refresh()
            } catch {
                installError = error.localizedDescription
            }
            isInstalling = false
        }
    }

    private func check() {
        isChecking = true
        checkResult = nil

        Task {
            do {
                switch try await DiarizationModelStore.compareWithRemote() {
                case .upToDate(_, let date):
                    checkResult = .upToDate(date)
                case .updateAvailable(_, let date, let changed):
                    checkResult = .updateAvailable(date, changedFiles: changed)
                }
                refresh()
            } catch {
                checkResult = .failed(error.localizedDescription)
            }
            isChecking = false
        }
    }

    /// Remove the local copies so the next meeting fetches fresh ones.
    ///
    /// Deleting rather than overwriting: FluidAudio skips any file already on disk, so
    /// a stale copy would survive a re-download untouched.
    private func update() {
        isUpdating = true

        Task {
            do {
                try DiarizationModelStore.removeLocalCopies()
                checkResult = nil
                refresh()
            } catch {
                checkResult = .failed(error.localizedDescription)
            }
            isUpdating = false
        }
    }
}
#endif

// MARK: - Meeting Audio (macOS only)

#if os(macOS)
/// Whether meetings capture system playback as well as the microphone.
struct MeetingAudioSection: View {
    @Environment(AppSettings.self) private var settings

    @State private var permissionChecked = false
    @State private var hasPermission = false

    var body: some View {
        @Bindable var settings = settings

        VStack(alignment: .leading, spacing: 10) {
            Toggle("Keep the recording after a meeting ends", isOn: $settings.keepMeetingAudio)

            Text("Lets you play back a line to check whether a speaker was attributed correctly, and re-run separation later. Roughly 30 MB an hour.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if MeetingAudioStore.totalSize() > 0 {
                Text("Recordings currently use \(MeetingAudioStore.formatted(bytes: MeetingAudioStore.totalSize())).")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Divider()

            Toggle("Record system audio during meetings", isOn: $settings.captureSystemAudioInMeetings)

            Text("Without this a meeting captures only your microphone, so on a video call the other participants are never transcribed and speaker separation has nothing to separate.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if settings.captureSystemAudioInMeetings {
                if permissionChecked && !hasPermission {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("macOS has not granted system audio recording.", systemImage: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)

                        Button("Open System Settings") {
                            SystemAudioCapture.openSystemSettings()
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                } else if permissionChecked {
                    Label("System audio recording is available.", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }

                Button(permissionChecked ? "Check Again" : "Check Permission") {
                    hasPermission = SystemAudioCapture.checkAvailability()
                    permissionChecked = true
                }
                .font(.caption)

                Text("This records everyone audible on the call, not only you. Check that the people you are meeting with are content to be recorded.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}
#endif
