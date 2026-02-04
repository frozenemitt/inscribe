import Foundation

// MARK: - Prompt Model

/// A customizable AI prompt for text processing
public struct Prompt: Identifiable, Codable, Equatable, Hashable {
    public let id: UUID
    public var name: String
    public var systemPrompt: String
    public var userTemplate: String  // Use {text} as placeholder for transcribed text
    public var isBuiltIn: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        systemPrompt: String,
        userTemplate: String,
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.systemPrompt = systemPrompt
        self.userTemplate = userTemplate
        self.isBuiltIn = isBuiltIn
    }

    /// Apply the prompt template to transcribed text
    public func apply(to text: String) -> String {
        userTemplate.replacingOccurrences(of: "{text}", with: text)
    }
}

// MARK: - Prompt Manager

/// Manages custom AI prompts with iCloud synchronization
@Observable
public final class PromptConfiguration {

    // MARK: - Published State

    public private(set) var prompts: [Prompt] = []
    public private(set) var iCloudAvailable: Bool = false

    // MARK: - Storage Keys

    private let iCloudKey = "customPrompts"
    private let localKey = "customPrompts"

    // MARK: - Built-in Prompts

    public static let builtInPrompts: [Prompt] = [
        Prompt(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "Clean Up",
            systemPrompt: "You are a text editor. Clean up the transcribed text for clarity and grammar while preserving the original meaning and tone.",
            userTemplate: "Please clean up this transcribed text, fixing any grammar issues and improving clarity:\n\n{text}",
            isBuiltIn: true
        ),
        Prompt(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            name: "Summarize",
            systemPrompt: "You are a summarization assistant. Create concise bullet-point summaries.",
            userTemplate: "Summarize the following text as bullet points:\n\n{text}",
            isBuiltIn: true
        ),
        Prompt(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            name: "Make Formal",
            systemPrompt: "You are a professional writing assistant. Convert casual speech to formal written language.",
            userTemplate: "Rewrite the following in a formal, professional tone:\n\n{text}",
            isBuiltIn: true
        ),
        Prompt(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
            name: "Make Casual",
            systemPrompt: "You are a friendly writing assistant. Convert formal text to casual, conversational language.",
            userTemplate: "Rewrite the following in a casual, friendly tone:\n\n{text}",
            isBuiltIn: true
        ),
        Prompt(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
            name: "Fix Punctuation",
            systemPrompt: "You are a punctuation expert. Add proper punctuation to transcribed speech without changing any words.",
            userTemplate: "Add proper punctuation to this text without changing any words:\n\n{text}",
            isBuiltIn: true
        ),
        Prompt(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
            name: "Raw (No Processing)",
            systemPrompt: "",
            userTemplate: "{text}",
            isBuiltIn: true
        )
    ]

    /// The "Raw" prompt ID for skipping AI processing
    public static let rawPromptId = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    /// The default "Clean Up" prompt ID
    public static let defaultPromptId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    // MARK: - Initialization

    public init() {
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
    public func prompt(withId id: UUID) -> Prompt? {
        prompts.first { $0.id == id }
    }

    /// Get all custom (non-built-in) prompts
    public var customPrompts: [Prompt] {
        prompts.filter { !$0.isBuiltIn }
    }

    /// Get all built-in prompts
    public var builtInPromptsList: [Prompt] {
        prompts.filter { $0.isBuiltIn }
    }

    /// Add a new custom prompt
    public func addPrompt(_ prompt: Prompt) {
        var newPrompt = prompt
        newPrompt = Prompt(
            id: prompt.id,
            name: prompt.name,
            systemPrompt: prompt.systemPrompt,
            userTemplate: prompt.userTemplate,
            isBuiltIn: false  // Custom prompts are never built-in
        )
        prompts.append(newPrompt)
        savePrompts()
        print("[PromptConfiguration] Added prompt: \(newPrompt.name)")
    }

    /// Create and add a new prompt
    public func createPrompt(name: String, systemPrompt: String, userTemplate: String) -> Prompt {
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
    public func updatePrompt(_ prompt: Prompt) {
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
    public func deletePrompt(withId id: UUID) {
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
    public func movePrompt(from source: IndexSet, to destination: Int) {
        prompts.move(fromOffsets: source, toOffset: destination)
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

        self.prompts = loadedPrompts
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
    public func syncWithiCloud() {
        guard iCloudAvailable else {
            print("[PromptConfiguration] iCloud not available")
            return
        }

        NSUbiquitousKeyValueStore.default.synchronize()
        loadPrompts()
        print("[PromptConfiguration] Synced with iCloud")
    }
}
