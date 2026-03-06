import Foundation
import FoundationModels

// MARK: - Sampling Mode

/// Controls how the model selects tokens during generation
enum SamplingMode: Equatable, Hashable {
    case automatic           // Framework default (random sampling)
    case greedy              // Deterministic — always picks most likely token
    case topP(Double)        // Sample from tokens within cumulative probability threshold
    case topK(Int)           // Sample from top K most likely tokens

    /// Display name for the UI picker
    var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        case .greedy: return "Greedy"
        case .topP: return "Top-P"
        case .topK: return "Top-K"
        }
    }

    /// Convert to a simple case tag for the picker (ignoring associated values)
    var caseTag: String {
        switch self {
        case .automatic: return "automatic"
        case .greedy: return "greedy"
        case .topP: return "topP"
        case .topK: return "topK"
        }
    }
}

// MARK: - SamplingMode Codable

extension SamplingMode: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, value
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "automatic":
            self = .automatic
        case "greedy":
            self = .greedy
        case "topP":
            let threshold = try container.decode(Double.self, forKey: .value)
            self = .topP(threshold)
        case "topK":
            let k = try container.decode(Int.self, forKey: .value)
            self = .topK(k)
        default:
            self = .automatic
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .automatic:
            try container.encode("automatic", forKey: .type)
        case .greedy:
            try container.encode("greedy", forKey: .type)
        case .topP(let threshold):
            try container.encode("topP", forKey: .type)
            try container.encode(threshold, forKey: .value)
        case .topK(let k):
            try container.encode("topK", forKey: .type)
            try container.encode(k, forKey: .value)
        }
    }
}

// MARK: - Prompt Model

/// A customizable AI prompt for text processing
struct Prompt: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var name: String
    var systemPrompt: String
    var userTemplate: String  // Use {text} as placeholder for transcribed text
    var isBuiltIn: Bool
    var isVisible: Bool

    // Generation settings (per-prompt tuning)
    var temperature: Double
    var samplingMode: SamplingMode
    var maxResponseTokens: Int?

    init(
        id: UUID = UUID(),
        name: String,
        systemPrompt: String,
        userTemplate: String,
        isBuiltIn: Bool = false,
        isVisible: Bool = true,
        temperature: Double = 0.5,
        samplingMode: SamplingMode = .automatic,
        maxResponseTokens: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.systemPrompt = systemPrompt
        self.userTemplate = userTemplate
        self.isBuiltIn = isBuiltIn
        self.isVisible = isVisible
        self.temperature = temperature
        self.samplingMode = samplingMode
        self.maxResponseTokens = maxResponseTokens
    }

    // Custom decoder for backward compatibility with saved prompts missing new fields
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        systemPrompt = try container.decode(String.self, forKey: .systemPrompt)
        userTemplate = try container.decode(String.self, forKey: .userTemplate)
        isBuiltIn = try container.decode(Bool.self, forKey: .isBuiltIn)
        isVisible = try container.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature) ?? 0.5
        samplingMode = try container.decodeIfPresent(SamplingMode.self, forKey: .samplingMode) ?? .automatic
        maxResponseTokens = try container.decodeIfPresent(Int.self, forKey: .maxResponseTokens)
    }

    /// Apply the prompt template to transcribed text.
    /// Wraps the transcription in <transcription> tags so the model can
    /// clearly distinguish the instructions from the content to process.
    func apply(to text: String) -> String {
        let trimmed = userTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(trimmed)\n\n<transcription>\n\(text)\n</transcription>"
    }

    /// Build GenerationOptions from this prompt's per-prompt settings
    func generationOptions() -> GenerationOptions {
        let sampling: GenerationOptions.SamplingMode? = switch samplingMode {
        case .automatic: nil
        case .greedy: .greedy
        case .topP(let threshold): .random(probabilityThreshold: threshold)
        case .topK(let k): .random(top: k)
        }

        if let sampling {
            return GenerationOptions(sampling: sampling, temperature: temperature)
        }
        return GenerationOptions(temperature: temperature)
    }
}

// MARK: - Prompt Manager

/// Manages custom AI prompts with iCloud synchronization
@Observable
final class PromptConfiguration {

    // MARK: - Published State

    private(set) var prompts: [Prompt] = []
    private(set) var iCloudAvailable: Bool = false

    // MARK: - Storage Keys

    private let iCloudKey = "customPrompts"
    private let localKey = "customPrompts"
    private let visibilityKey = "promptVisibility"
    private let generationSettingsKey = "promptGenerationSettings"

    // MARK: - Built-in Prompts

    static let builtInPrompts: [Prompt] = [
        Prompt(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "Clean Up",
            systemPrompt: "You are an expert editor specializing in cleaning spoken transcriptions into polished written prose.",
            userTemplate: """
            Clean up the following transcribed speech into polished written text.

            - Remove filler words (um, uh, like, you know, so, basically, I mean)
            - Rewrite confusing or poorly worded phrases for clarity
            - Eliminate repetitions, false starts, and tangents
            - Combine run-on sentences into clear, concise ones
            - Add paragraph breaks where the topic shifts
            - Improve grammar, punctuation, and sentence structure
            - Add proper punctuation marks throughout
            - Preserve the original meaning, tone, and intent
            """,
            isBuiltIn: true
        ),
        Prompt(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            name: "Summarize",
            systemPrompt: "You are an expert summarizer specializing in distilling spoken transcriptions into concise, structured summaries.",
            userTemplate: """
            Summarize the following transcribed speech into a concise, structured summary.

            - Identify the key points and main ideas
            - Group related points by theme or topic
            - Use a bulleted list format for clarity
            - Preserve important details, names, numbers, and decisions
            - Remove filler words, repetitions, and tangents
            - Keep the original meaning and intent intact
            - Be concise — aim for roughly 20-30% of the original length
            """,
            isBuiltIn: true
        ),
        Prompt(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            name: "Make Formal",
            systemPrompt: "You are an expert editor specializing in transforming casual spoken transcriptions into polished, professional written prose.",
            userTemplate: """
            Rewrite the following transcribed speech in a formal, professional tone.

            - Elevate vocabulary and use precise, professional language
            - Replace slang, colloquialisms, and casual expressions with formal equivalents
            - Use complete, well-structured sentences
            - Maintain a professional and authoritative tone throughout
            - Preserve the original meaning and key information
            - Add proper structure with paragraph breaks at topic changes
            - Improve grammar, punctuation, and sentence flow
            - Remove filler words, repetitions, and false starts
            """,
            isBuiltIn: true
        ),
        Prompt(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
            name: "Make Casual",
            systemPrompt: "You are an expert editor specializing in transforming formal or stiff transcriptions into natural, conversational written prose.",
            userTemplate: """
            Rewrite the following transcribed speech in a casual, friendly tone.

            - Use everyday, conversational language
            - Replace jargon or overly formal words with simpler alternatives
            - Keep a friendly, approachable tone throughout
            - Use contractions naturally (don't, can't, it's, etc.)
            - Preserve the original meaning and key information
            - Clean up filler words, repetitions, and false starts
            - Add paragraph breaks where the topic shifts
            - Improve grammar and punctuation while keeping it relaxed
            """,
            isBuiltIn: true
        ),
        Prompt(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
            name: "Fix Punctuation",
            systemPrompt: "You are an expert punctuation editor specializing in adding proper punctuation to spoken transcriptions without altering any words.",
            userTemplate: """
            Add proper punctuation to the following transcribed speech.

            - Add periods, commas, question marks, and exclamation points where appropriate
            - Add paragraph breaks where the topic or thought changes
            - Use em dashes, semicolons, and colons where they improve readability
            - Capitalize the first word of each sentence and proper nouns
            - Do NOT change, add, or remove any words — only add punctuation and capitalization
            - Preserve the exact wording and order of the original text
            """,
            isBuiltIn: true
        ),
        Prompt(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
            name: "Raw (No Processing)",
            systemPrompt: "",
            userTemplate: "",
            isBuiltIn: true
        )
    ]

    /// The "Raw" prompt ID for skipping AI processing
    static let rawPromptId = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    /// The default "Clean Up" prompt ID
    static let defaultPromptId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    // MARK: - Initialization

    init() {
        // Check iCloud availability
        iCloudAvailable = NSUbiquitousKeyValueStore.default.synchronize()

        // Load prompts
        loadPrompts()

        // Listen for iCloud changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(iCloudDidChange),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default
        )

        print("[PromptConfiguration] Initialized with \(prompts.count) prompts, iCloud: \(iCloudAvailable)")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Public API

    /// Get a prompt by ID
    func prompt(withId id: UUID) -> Prompt? {
        prompts.first { $0.id == id }
    }

    /// Get all custom (non-built-in) prompts
    var customPrompts: [Prompt] {
        prompts.filter { !$0.isBuiltIn }
    }

    /// Get all built-in prompts
    var builtInPromptsList: [Prompt] {
        prompts.filter { $0.isBuiltIn }
    }

    /// Get only prompts marked as visible (for the menu bar dropdown)
    var visiblePrompts: [Prompt] {
        prompts.filter { $0.isVisible }
    }

    /// Toggle visibility for a prompt (works for both built-in and custom)
    func toggleVisibility(promptId: UUID) {
        guard let index = prompts.firstIndex(where: { $0.id == promptId }) else { return }
        prompts[index].isVisible.toggle()
        saveVisibility()
        if !prompts[index].isBuiltIn {
            savePrompts()
        }
    }

    /// Set visibility for a prompt
    func setVisibility(promptId: UUID, visible: Bool) {
        guard let index = prompts.firstIndex(where: { $0.id == promptId }) else { return }
        prompts[index].isVisible = visible
        saveVisibility()
        if !prompts[index].isBuiltIn {
            savePrompts()
        }
    }

    /// Update generation settings for any prompt (including built-in)
    func updateGenerationSettings(
        promptId: UUID,
        temperature: Double,
        samplingMode: SamplingMode,
        maxResponseTokens: Int?
    ) {
        guard let index = prompts.firstIndex(where: { $0.id == promptId }) else { return }
        prompts[index].temperature = temperature
        prompts[index].samplingMode = samplingMode
        prompts[index].maxResponseTokens = maxResponseTokens

        if prompts[index].isBuiltIn {
            saveGenerationSettings()
        } else {
            savePrompts()
        }
        print("[PromptConfiguration] Updated generation settings for: \(prompts[index].name)")
    }

    /// Add a new custom prompt
    func addPrompt(_ prompt: Prompt) {
        let newPrompt = Prompt(
            id: prompt.id,
            name: prompt.name,
            systemPrompt: prompt.systemPrompt,
            userTemplate: prompt.userTemplate,
            isBuiltIn: false,
            isVisible: prompt.isVisible,
            temperature: prompt.temperature,
            samplingMode: prompt.samplingMode,
            maxResponseTokens: prompt.maxResponseTokens
        )
        prompts.append(newPrompt)
        savePrompts()
        print("[PromptConfiguration] Added prompt: \(newPrompt.name)")
    }

    /// Create and add a new prompt
    func createPrompt(name: String, systemPrompt: String, userTemplate: String) -> Prompt {
        let prompt = Prompt(
            name: name,
            systemPrompt: systemPrompt,
            userTemplate: userTemplate,
            isBuiltIn: false
        )
        addPrompt(prompt)
        return prompt
    }

    /// Update an existing prompt (only custom prompts can be updated)
    func updatePrompt(_ prompt: Prompt) {
        guard let index = prompts.firstIndex(where: { $0.id == prompt.id }) else {
            print("[PromptConfiguration] Prompt not found for update: \(prompt.id)")
            return
        }

        guard !prompts[index].isBuiltIn else {
            print("[PromptConfiguration] Cannot update built-in prompt: \(prompt.name)")
            return
        }

        prompts[index] = prompt
        savePrompts()
        print("[PromptConfiguration] Updated prompt: \(prompt.name)")
    }

    /// Delete a prompt (only custom prompts can be deleted)
    func deletePrompt(withId id: UUID) {
        guard let index = prompts.firstIndex(where: { $0.id == id }) else {
            print("[PromptConfiguration] Prompt not found for deletion: \(id)")
            return
        }

        guard !prompts[index].isBuiltIn else {
            print("[PromptConfiguration] Cannot delete built-in prompt")
            return
        }

        let removed = prompts.remove(at: index)
        savePrompts()
        print("[PromptConfiguration] Deleted prompt: \(removed.name)")
    }

    /// Reorder prompts
    func movePrompt(from source: IndexSet, to destination: Int) {
        // Manually implement move without SwiftUI dependency
        let itemsToMove = source.sorted().compactMap { index in
            index < prompts.count ? prompts[index] : nil
        }
        
        // Remove items (in reverse order to maintain indices)
        for index in source.sorted(by: >) {
            if index < prompts.count {
                prompts.remove(at: index)
            }
        }
        
        // Calculate adjusted destination
        let adjustedDestination = source.reduce(destination) { destination, sourceIndex in
            sourceIndex < destination ? destination - 1 : destination
        }
        
        // Insert items at destination
        prompts.insert(contentsOf: itemsToMove, at: adjustedDestination)
        savePrompts()
    }

    // MARK: - Persistence

    private func loadPrompts() {
        // Start with built-in prompts
        var loadedPrompts = Self.builtInPrompts

        // Try to load custom prompts from iCloud first, then local storage
        let customData: Data?
        if iCloudAvailable, let iCloudData = NSUbiquitousKeyValueStore.default.data(forKey: iCloudKey) {
            customData = iCloudData
            print("[PromptConfiguration] Loaded from iCloud")
        } else if let localData = UserDefaults.standard.data(forKey: localKey) {
            customData = localData
            print("[PromptConfiguration] Loaded from local storage")
        } else {
            customData = nil
        }

        if let data = customData {
            do {
                let customPrompts = try JSONDecoder().decode([Prompt].self, from: data)
                loadedPrompts.append(contentsOf: customPrompts.filter { !$0.isBuiltIn })
                print("[PromptConfiguration] Loaded \(customPrompts.count) custom prompts")
            } catch {
                print("[PromptConfiguration] Error decoding prompts: \(error)")
            }
        }

        // Apply saved visibility settings (for built-in prompts)
        let savedVisibility = loadVisibility()
        for (index, prompt) in loadedPrompts.enumerated() {
            if let visible = savedVisibility[prompt.id.uuidString] {
                loadedPrompts[index].isVisible = visible
            }
        }

        // Apply saved generation settings (for built-in prompts)
        let savedGenSettings = loadGenerationSettings()
        for (index, prompt) in loadedPrompts.enumerated() where prompt.isBuiltIn {
            if let settings = savedGenSettings[prompt.id.uuidString] {
                loadedPrompts[index].temperature = settings.temperature
                loadedPrompts[index].samplingMode = settings.samplingMode
                loadedPrompts[index].maxResponseTokens = settings.maxResponseTokens
            }
        }

        self.prompts = loadedPrompts
    }

    private func saveVisibility() {
        // Save visibility map for all prompts (keyed by UUID string)
        var visibilityMap: [String: Bool] = [:]
        for prompt in prompts {
            visibilityMap[prompt.id.uuidString] = prompt.isVisible
        }
        UserDefaults.standard.set(visibilityMap, forKey: visibilityKey)
    }

    private func loadVisibility() -> [String: Bool] {
        return UserDefaults.standard.dictionary(forKey: visibilityKey) as? [String: Bool] ?? [:]
    }

    // MARK: - Generation Settings Persistence (for built-in prompts)

    /// Codable container for persisting per-prompt generation settings
    private struct StoredGenerationSettings: Codable {
        var temperature: Double
        var samplingMode: SamplingMode
        var maxResponseTokens: Int?
    }

    private func saveGenerationSettings() {
        var settingsMap: [String: StoredGenerationSettings] = [:]
        for prompt in prompts where prompt.isBuiltIn {
            settingsMap[prompt.id.uuidString] = StoredGenerationSettings(
                temperature: prompt.temperature,
                samplingMode: prompt.samplingMode,
                maxResponseTokens: prompt.maxResponseTokens
            )
        }
        if let data = try? JSONEncoder().encode(settingsMap) {
            UserDefaults.standard.set(data, forKey: generationSettingsKey)
        }
    }

    private func loadGenerationSettings() -> [String: StoredGenerationSettings] {
        guard let data = UserDefaults.standard.data(forKey: generationSettingsKey) else { return [:] }
        return (try? JSONDecoder().decode([String: StoredGenerationSettings].self, from: data)) ?? [:]
    }

    private func savePrompts() {
        // Only save custom prompts
        let customPrompts = prompts.filter { !$0.isBuiltIn }

        do {
            let data = try JSONEncoder().encode(customPrompts)

            // Save to local storage
            UserDefaults.standard.set(data, forKey: localKey)

            // Save to iCloud if available
            if iCloudAvailable {
                NSUbiquitousKeyValueStore.default.set(data, forKey: iCloudKey)
                NSUbiquitousKeyValueStore.default.synchronize()
                print("[PromptConfiguration] Saved to iCloud")
            }

            print("[PromptConfiguration] Saved \(customPrompts.count) custom prompts")
        } catch {
            print("[PromptConfiguration] Error encoding prompts: \(error)")
        }
    }

    // MARK: - iCloud Sync

    @objc private func iCloudDidChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let changeReason = userInfo[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int else {
            return
        }

        print("[PromptConfiguration] iCloud change detected, reason: \(changeReason)")

        // Reload prompts on external changes
        if changeReason == NSUbiquitousKeyValueStoreServerChange ||
           changeReason == NSUbiquitousKeyValueStoreInitialSyncChange {
            loadPrompts()
        }
    }

    /// Force sync with iCloud
    func syncWithiCloud() {
        guard iCloudAvailable else {
            print("[PromptConfiguration] iCloud not available")
            return
        }

        NSUbiquitousKeyValueStore.default.synchronize()
        loadPrompts()
        print("[PromptConfiguration] Synced with iCloud")
    }
}
