import SwiftUI

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

            PromptsSettingsView()
                .tabItem {
                    Label("Prompts", systemImage: "text.bubble")
                }

            HotkeySettingsView()
                .tabItem {
                    Label("Hotkey", systemImage: "keyboard")
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
                Toggle("Copy to clipboard automatically", isOn: $settings.copyToClipboardAutomatically)
                Toggle("Play feedback sounds", isOn: $settings.playFeedbackSounds)
                Toggle("Show notifications", isOn: $settings.showNotifications)
            }

            Section {
                Button("Reset to Defaults") {
                    settings.resetToDefaults()
                }
            }
        }
        .formStyle(.grouped)
        #if os(iOS)
        .navigationTitle("General")
        .navigationBarTitleDisplayMode(.inline)
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
        for index in indexSet {
            let prompt = promptConfig.customPrompts[index]
            promptConfig.deletePrompt(withId: prompt.id)
        }
        selectedPromptId = promptConfig.prompts.first?.id
    }

    private func deletePrompt(id: UUID) {
        promptConfig.deletePrompt(withId: id)
        selectedPromptId = promptConfig.prompts.first?.id
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
        .onChange(of: prompt) { _, newPrompt in
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

// MARK: - Hotkey Settings (macOS only)

#if os(macOS)
struct HotkeySettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(HotkeyService.self) private var hotkeyService

    @State private var isRecordingHotkey = false
    @State private var eventMonitor: Any?

    var body: some View {
        Form {
            Section("Global Hotkey") {
                HStack {
                    Text("Current Hotkey:")

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

                if hotkeyService.isRegistered {
                    Label("Hotkey is active", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if let error = hotkeyService.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }

            Section {
                Text("Press a key combination with at least one modifier (⌃, ⌥, or ⌘) to set a global hotkey.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: isRecordingHotkey) { _, recording in
            if recording {
                startMonitoring()
            } else {
                stopMonitoring()
            }
        }
        .onDisappear {
            stopMonitoring()
            isRecordingHotkey = false
        }
    }

    private func startMonitoring() {
        stopMonitoring()

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Escape cancels recording
            if event.keyCode == 53 {
                isRecordingHotkey = false
                return nil
            }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let hasModifier = flags.contains(.control) || flags.contains(.option) || flags.contains(.command)

            guard hasModifier else { return nil }

            guard let char = characterForKeyCode(event.keyCode) else { return nil }

            var parts = ""
            if flags.contains(.control) { parts += "⌃" }
            if flags.contains(.option) { parts += "⌥" }
            if flags.contains(.shift) { parts += "⇧" }
            if flags.contains(.command) { parts += "⌘" }
            parts += String(char).uppercased()

            settings.hotkeyString = parts
            hotkeyService.registerHotkey(from: parts)
            isRecordingHotkey = false

            return nil
        }
    }

    private func stopMonitoring() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    private func characterForKeyCode(_ keyCode: UInt16) -> Character? {
        let map: [UInt16: Character] = [
            0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x",
            8: "c", 9: "v", 11: "b", 12: "q", 13: "w", 14: "e", 15: "r",
            16: "y", 17: "t", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "o", 32: "u", 33: "[", 34: "i", 35: "p", 37: "l",
            38: "j", 39: "'", 40: "k", 41: ";", 42: "\\", 43: ",", 44: "/",
            45: "n", 46: "m", 47: ".", 49: " "
        ]
        return map[keyCode]
    }
}
#endif

// MARK: - About Settings

struct AboutSettingsView: View {
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
        .environment(HotkeyService())
        #endif
}
