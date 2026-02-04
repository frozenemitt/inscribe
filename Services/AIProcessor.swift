import Foundation
import FoundationModels

/// AI-powered text processor using Apple's on-device FoundationModels
@MainActor
public final class AIProcessor: ObservableObject {

    // MARK: - Published State

    @Published public private(set) var isProcessing = false
    @Published public private(set) var lastError: AIProcessorError?

    // MARK: - Configuration

    private let promptConfiguration: PromptConfiguration

    // MARK: - Available Models

    /// Represents an available AI model
    public struct AIModel: Identifiable, Equatable, Hashable {
        public let id: String
        public let name: String
        public let description: String

        public init(id: String, name: String, description: String) {
            self.id = id
            self.name = name
            self.description = description
        }
    }

    /// Available models from Apple's FoundationModels framework
    public static let availableModels: [AIModel] = [
        AIModel(
            id: "default",
            name: "Default",
            description: "Apple's default on-device language model"
        )
        // Additional models can be added here as Apple exposes more options
    ]

    /// The currently selected model ID
    public var selectedModelId: String = "default"

    // MARK: - Initialization

    public init(promptConfiguration: PromptConfiguration) {
        self.promptConfiguration = promptConfiguration
    }

    // MARK: - Public API

    /// Process text with the specified prompt
    /// - Parameters:
    ///   - text: The transcribed text to process
    ///   - promptId: The ID of the prompt to use (nil = use default)
    /// - Returns: Processed text
    public func process(text: String, promptId: UUID? = nil) async throws -> String {
        // Get the prompt
        let effectivePromptId = promptId ?? PromptConfiguration.defaultPromptId
        guard let prompt = promptConfiguration.prompt(withId: effectivePromptId) else {
            throw AIProcessorError.promptNotFound
        }

        // Skip processing for "Raw" prompt
        if prompt.id == PromptConfiguration.rawPromptId {
            print("[AIProcessor] Using raw prompt, returning text unchanged")
            return text
        }

        return try await processWithPrompt(text: text, prompt: prompt)
    }

    /// Process text with a custom prompt (not from configuration)
    /// - Parameters:
    ///   - text: The transcribed text to process
    ///   - systemPrompt: The system prompt for the AI
    ///   - userPrompt: The user prompt template (use {text} as placeholder)
    /// - Returns: Processed text
    public func processWithCustomPrompt(
        text: String,
        systemPrompt: String,
        userPrompt: String
    ) async throws -> String {
        let prompt = Prompt(
            name: "Custom",
            systemPrompt: systemPrompt,
            userTemplate: userPrompt
        )
        return try await processWithPrompt(text: text, prompt: prompt)
    }

    /// Quick process with a built-in action
    /// - Parameters:
    ///   - text: The text to process
    ///   - action: The action to perform
    /// - Returns: Processed text
    public func quickProcess(text: String, action: QuickAction) async throws -> String {
        let promptId: UUID
        switch action {
        case .cleanup:
            promptId = PromptConfiguration.defaultPromptId
        case .summarize:
            promptId = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        case .makeFormal:
            promptId = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        case .makeCasual:
            promptId = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        case .fixPunctuation:
            promptId = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
        case .raw:
            return text
        }

        return try await process(text: text, promptId: promptId)
    }

    // MARK: - Private Implementation

    private func processWithPrompt(text: String, prompt: Prompt) async throws -> String {
        guard !text.isEmpty else {
            throw AIProcessorError.emptyInput
        }

        guard !isProcessing else {
            throw AIProcessorError.alreadyProcessing
        }

        // Check language support
        guard FoundationModelsHelper.isCurrentLocaleSupported() else {
            throw AIProcessorError.languageNotSupported
        }

        isProcessing = true
        lastError = nil

        defer {
            isProcessing = false
        }

        print("[AIProcessor] Processing with prompt: \(prompt.name)")

        do {
            // Create session with the prompt's system instructions
            let session = FoundationModelsHelper.createSession(instructions: prompt.systemPrompt)

            // Apply the user template to the text
            let userPrompt = prompt.apply(to: text)

            // Generate response with balanced temperature
            let options = GenerationOptions(temperature: 0.4)
            let result = try await FoundationModelsHelper.generateText(
                session: session,
                prompt: userPrompt,
                options: options
            )

            print("[AIProcessor] Processing complete, result length: \(result.count)")
            return result

        } catch FoundationModelsError.contextWindowExceeded {
            lastError = .contextWindowExceeded
            throw AIProcessorError.contextWindowExceeded
        } catch FoundationModelsError.unsupportedLanguage {
            lastError = .languageNotSupported
            throw AIProcessorError.languageNotSupported
        } catch {
            lastError = .processingFailed(error.localizedDescription)
            throw AIProcessorError.processingFailed(error.localizedDescription)
        }
    }

    // MARK: - Model Information

    /// Check if AI processing is available on this device
    public static var isAvailable: Bool {
        FoundationModelsHelper.isCurrentLocaleSupported()
    }

    /// Get supported languages
    public static var supportedLanguages: [Locale.Language] {
        FoundationModelsHelper.getSupportedLanguages()
    }
}

// MARK: - Quick Actions

extension AIProcessor {
    /// Quick actions for common text processing tasks
    public enum QuickAction: String, CaseIterable, Identifiable {
        case cleanup = "cleanup"
        case summarize = "summarize"
        case makeFormal = "formal"
        case makeCasual = "casual"
        case fixPunctuation = "punctuation"
        case raw = "raw"

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .cleanup: return "Clean Up"
            case .summarize: return "Summarize"
            case .makeFormal: return "Make Formal"
            case .makeCasual: return "Make Casual"
            case .fixPunctuation: return "Fix Punctuation"
            case .raw: return "Raw (No Processing)"
            }
        }

        public var icon: String {
            switch self {
            case .cleanup: return "sparkles"
            case .summarize: return "list.bullet"
            case .makeFormal: return "briefcase"
            case .makeCasual: return "face.smiling"
            case .fixPunctuation: return "textformat"
            case .raw: return "doc.text"
            }
        }
    }
}

// MARK: - Errors

public enum AIProcessorError: Error, LocalizedError {
    case promptNotFound
    case emptyInput
    case alreadyProcessing
    case languageNotSupported
    case contextWindowExceeded
    case processingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .promptNotFound:
            return "The selected prompt could not be found"
        case .emptyInput:
            return "No text to process"
        case .alreadyProcessing:
            return "Already processing a request"
        case .languageNotSupported:
            return "The current language is not supported for AI processing"
        case .contextWindowExceeded:
            return "The text is too long to process"
        case .processingFailed(let reason):
            return "Processing failed: \(reason)"
        }
    }
}
