import Foundation
import os
import FoundationModels
import Observation

// MARK: - Structured Output

/// Constrains the model to return only the processed text — no commentary or preamble.
/// The @Generable macro enforces a JSON schema at the token level, so the model
/// physically cannot produce output outside this single field.
@Generable
struct TranscriptionResult {
    @Guide(description: "The rewritten transcription text only, with no commentary or explanation")
    var text: String
}

/// AI-powered text processor using Apple's on-device FoundationModels
@MainActor
@Observable
final class AIProcessor {

    // MARK: - Published State

    private(set) var isProcessing = false
    private(set) var lastError: AIProcessorError?

    /// A session built and loaded while the user was still speaking.
    ///
    /// The model has to be in memory before it can answer, and that load used to begin
    /// only once the dictation had finished — seconds the user spends watching a
    /// spinner, when they had just spent seconds talking. Starting it at the same
    /// moment as the recording hides the whole thing behind speech.
    ///
    /// Used once and dropped. A `LanguageModelSession` carries its own transcript, so
    /// keeping one across dictations would let the last one see the one before it.
    private var warmSession: LanguageModelSession?
    private var warmPromptId: UUID?

    // MARK: - Configuration

    let promptConfiguration: PromptConfiguration

    // MARK: - Available Models

    /// Represents an available AI model
    struct AIModel: Identifiable, Equatable, Hashable {
        public let id: String
        public let name: String
        public let description: String

        init(id: String, name: String, description: String) {
            self.id = id
            self.name = name
            self.description = description
        }
    }

    /// Available models from Apple's FoundationModels framework
    static let availableModels: [AIModel] = [
        AIModel(
            id: "default",
            name: "Default",
            description: "Apple's default on-device language model"
        )
        // Additional models can be added here as Apple exposes more options
    ]

    /// The currently selected model ID
    var selectedModelId: String = "default"

    // MARK: - Initialization

    init(promptConfiguration: PromptConfiguration) {
        self.promptConfiguration = promptConfiguration
    }

    // MARK: - Public API

    /// Process text with the specified prompt
    /// - Parameters:
    ///   - text: The transcribed text to process
    ///   - promptId: The ID of the prompt to use (nil = use default)
    /// - Returns: Processed text
    /// - Parameter surroundingText: What is already in the field being dictated into.
    ///   Given to the model as background so a reply matches the thread it belongs to.
    ///   It is explicitly marked as context to be read but not rewritten.
    func process(
        text: String,
        promptId: UUID? = nil,
        surroundingText: String? = nil
    ) async throws -> String {
        // Get the prompt
        let effectivePromptId = promptId ?? PromptConfiguration.defaultPromptId
        guard let prompt = promptConfiguration.prompt(withId: effectivePromptId) else {
            throw AIProcessorError.promptNotFound
        }

        // Skip processing for "Raw" prompt
        if prompt.id == PromptConfiguration.rawPromptId {
            Log.ai.notice("Using raw prompt, returning text unchanged")
            return text
        }

        return try await processWithPrompt(
            text: text,
            prompt: prompt,
            surroundingText: surroundingText
        )
    }

    /// Process text with a custom prompt (not from configuration)
    /// - Parameters:
    ///   - text: The transcribed text to process
    ///   - systemPrompt: The system prompt for the AI
    ///   - userPrompt: The user prompt template (use {text} as placeholder)
    /// - Returns: Processed text
    func processWithCustomPrompt(
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
    func quickProcess(text: String, action: QuickAction) async throws -> String {
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

    /// Load the model for the prompt this dictation will use, while it is being spoken.
    ///
    /// Silent about failure on purpose: this is an optimisation, and a dictation whose
    /// prewarm did not happen simply takes as long as it used to.
    func prewarm(promptId: UUID?) {
        guard FoundationModelsHelper.isCurrentLocaleSupported() else { return }
        guard let prompt = resolvedPrompt(for: promptId) else { return }
        guard warmPromptId != prompt.id else { return }

        let session = FoundationModelsHelper.createSession(instructions: prompt.systemPrompt)
        session.prewarm()
        warmSession = session
        warmPromptId = prompt.id
        Log.ai.notice("prewarmed the model")
    }

    /// The prompt a dictation with this id will actually run, or nothing when it will
    /// not run one at all.
    private func resolvedPrompt(for promptId: UUID?) -> Prompt? {
        let id = promptId ?? PromptConfiguration.defaultPromptId
        guard let prompt = promptConfiguration.prompt(withId: id) else { return nil }
        guard prompt.id != PromptConfiguration.rawPromptId else { return nil }
        return prompt
    }

    /// Forget a warmed session that will not be used.
    func discardPrewarm() {
        warmSession = nil
        warmPromptId = nil
    }

    // MARK: - Private Implementation

    private func processWithPrompt(
        text: String,
        prompt: Prompt,
        surroundingText: String? = nil
    ) async throws -> String {
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

        Log.ai.notice("Processing with prompt: \(prompt.name)")

        do {
            // The session warmed while this was being spoken, if it was warmed for
            // this prompt. Taken rather than borrowed: a session carries its own
            // transcript, so the next dictation gets a fresh one.
            let session: LanguageModelSession
            if let warmSession, warmPromptId == prompt.id {
                session = warmSession
            } else {
                session = FoundationModelsHelper.createSession(instructions: prompt.systemPrompt)
            }
            discardPrewarm()

            // Apply the user template to the text
            var userPrompt = prompt.apply(to: text)

            // Prepended, and fenced off in its own tags, so the model treats it as
            // background rather than as more text to rewrite. Without the fencing the
            // model tends to "clean up" the surrounding document too and hand it back.
            if let surroundingText, !surroundingText.isEmpty {
                userPrompt = """
                    <context>
                    The user is dictating into a text field that already contains the \
                    following. Use it only to match tone, terminology and the thread of \
                    the conversation. Do not repeat it, summarise it, or include any of \
                    it in your reply.

                    \(surroundingText)
                    </context>

                    \(userPrompt)
                    """
            }

            // Use per-prompt generation settings with structured output
            let options = prompt.generationOptions()
            let result = try await FoundationModelsHelper.generateStructured(
                session: session,
                prompt: userPrompt,
                generating: TranscriptionResult.self,
                options: options
            )

            // Strip leaked <transcription> tags if the model echoes them back
            let cleaned = result.text
                .replacingOccurrences(of: "<transcription>", with: "")
                .replacingOccurrences(of: "</transcription>", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            Log.ai.notice("Processing complete, result length: \(cleaned.count, privacy: .public)")
            return cleaned

        } catch FoundationModelsError.contextWindowExceeded {
            lastError = .contextWindowExceeded
            throw AIProcessorError.contextWindowExceeded
        } catch FoundationModelsError.unsupportedLanguage {
            lastError = .languageNotSupported
            throw AIProcessorError.languageNotSupported
        } catch FoundationModelsError.guardrailViolation {
            lastError = .guardrailViolation
            throw AIProcessorError.guardrailViolation
        } catch {
            lastError = .processingFailed(error.localizedDescription)
            throw AIProcessorError.processingFailed(error.localizedDescription)
        }
    }

    // MARK: - Model Information

    /// Check if AI processing is available on this device
    static var isAvailable: Bool {
        FoundationModelsHelper.isCurrentLocaleSupported()
    }

    /// Get supported languages
    static var supportedLanguages: [Locale.Language] {
        FoundationModelsHelper.getSupportedLanguages()
    }
}

// MARK: - Quick Actions

extension AIProcessor {
    /// Quick actions for common text processing tasks
    enum QuickAction: String, CaseIterable, Identifiable {
        case cleanup = "cleanup"
        case summarize = "summarize"
        case makeFormal = "formal"
        case makeCasual = "casual"
        case fixPunctuation = "punctuation"
        case raw = "raw"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .cleanup: return "Clean Up"
            case .summarize: return "Summarize"
            case .makeFormal: return "Make Formal"
            case .makeCasual: return "Make Casual"
            case .fixPunctuation: return "Fix Punctuation"
            case .raw: return "Raw (No Processing)"
            }
        }

        var icon: String {
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

enum AIProcessorError: Error, LocalizedError {
    case promptNotFound
    case emptyInput
    case alreadyProcessing
    case languageNotSupported
    case contextWindowExceeded
    case guardrailViolation
    case processingFailed(String)

    var errorDescription: String? {
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
        case .guardrailViolation:
            return "The on-device model refused to process this content due to Apple's safety restrictions. Your original transcription is preserved — try the Raw (No Processing) prompt instead."
        case .processingFailed(let reason):
            return "Processing failed: \(reason)"
        }
    }
}
