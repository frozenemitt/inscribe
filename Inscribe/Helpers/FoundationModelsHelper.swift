import Foundation
import FoundationModels

/// A helper class for working with Foundation Models framework
/// Provides convenient methods for text generation, structured output, and session management
@MainActor
class FoundationModelsHelper {

    // MARK: - Model Configuration

    /// The shared language model configured with permissive guardrails.
    /// This allows the model to faithfully process user content that contains
    /// profanity or other language that default guardrails would reject.
    /// Apple's `.permissiveContentTransformations` is designed specifically for
    /// apps that transform existing user content (e.g. cleaning up transcriptions) —
    /// but developers on Apple's own forums have confirmed it only relaxes the
    /// checks applied to a plain `String` response, not to guided (`@Generable`)
    /// output. A structured request can still trip the guardrail that the
    /// equivalent free-text request would have passed; see `generateTextAfterGuardrailViolation`.
    static let permissiveModel = SystemLanguageModel(
        guardrails: .permissiveContentTransformations
    )

    // MARK: - Session Management

    /// Creates a new session with custom instructions using permissive guardrails
    /// - Parameter instructions: The system instructions for the session
    /// - Returns: A configured LanguageModelSession
    static func createSession(instructions: String) -> LanguageModelSession {
        return LanguageModelSession(model: permissiveModel, instructions: instructions)
    }

    /// Creates a session with tools using permissive guardrails
    /// - Parameters:
    ///   - instructions: The system instructions for the session
    ///   - tools: Array of tools to make available to the session
    /// - Returns: A configured LanguageModelSession with tools
    static func createSession<T: Tool>(instructions: String, tools: [T]) -> LanguageModelSession {
        return LanguageModelSession(model: permissiveModel, tools: tools, instructions: instructions)
    }

    // MARK: - Text Generation

    /// Generate text response with automatic error handling
    /// - Parameters:
    ///   - session: The language model session
    ///   - prompt: The user prompt
    ///   - options: Optional generation options for controlling sampling
    /// - Returns: Generated text content
    /// - Throws: FoundationModelsError for handled errors
    static func generateText(
        session: LanguageModelSession,
        prompt: String,
        options: GenerationOptions? = nil
    ) async throws -> String {
        do {
            let response: LanguageModelSession.Response<String>
            if let options = options {
                response = try await session.respond(to: prompt, options: options)
            } else {
                response = try await session.respond(to: prompt)
            }
            return response.content
        } catch {
            throw mapGenerationError(error)
        }
    }

    /// Generate structured output using Generable types
    /// - Parameters:
    ///   - session: The language model session
    ///   - prompt: The user prompt
    ///   - type: The Generable type to generate
    ///   - options: Optional generation options
    /// - Returns: An instance of the specified Generable type
    /// - Throws: FoundationModelsError for handled errors
    static func generateStructured<T: Generable>(
        session: LanguageModelSession,
        prompt: String,
        generating type: T.Type,
        options: GenerationOptions? = nil
    ) async throws -> T {
        do {
            let response: LanguageModelSession.Response<T>
            if let options = options {
                response = try await session.respond(to: prompt, generating: type, options: options)
            } else {
                response = try await session.respond(to: prompt, generating: type)
            }
            return response.content
        } catch {
            throw mapGenerationError(error)
        }
    }

    /// Translate whatever the framework threw into our own error type.
    ///
    /// The macOS 27 SDK throws the new top-level `LanguageModelError` for guardrail,
    /// context-window and language failures; `LanguageModelSession.GenerationError`,
    /// which used to be the only type for these, is deprecated but still exists and
    /// is what the same failures threw through macOS 26. The app's minimum target is
    /// macOS 26 while it is built against the macOS 27 SDK, so either type can arrive
    /// depending on which OS the user is actually running — both are checked here
    /// rather than trusting the SDK version this was compiled against.
    private static func mapGenerationError(_ error: any Error) -> FoundationModelsError {
        if #available(macOS 27.0, *) {
            if let error = error as? LanguageModelError {
                switch error {
                case .contextSizeExceeded:
                    return .contextWindowExceeded
                case .unsupportedLanguageOrLocale:
                    return .unsupportedLanguage
                case .guardrailViolation:
                    return .guardrailViolation
                default:
                    return .generationFailed(error)
                }
            }
        }

        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize:
                return .contextWindowExceeded
            case .unsupportedLanguageOrLocale:
                return .unsupportedLanguage
            case .guardrailViolation:
                return .guardrailViolation
            default:
                return .generationFailed(error)
            }
        }

        return .generationFailed(error)
    }

    // MARK: - Guardrail Recovery

    /// Retry a guardrail-refused structured request as plain text.
    ///
    /// `.permissiveContentTransformations` does not relax the checks applied to
    /// guided (`@Generable`) generation — only to a plain `String` response — so a
    /// prompt that trips the guardrail as structured output can still often succeed
    /// once asked for free text instead. Builds a fresh session with the same
    /// instructions rather than reusing the failed one, since the refusal is now
    /// part of that session's transcript and would colour every turn after it.
    /// - Returns: The model's text, with a leading commentary line (e.g. "Here is
    ///   the rewritten text:") stripped if the model added one.
    static func generateTextAfterGuardrailViolation(
        instructions: String,
        prompt: String,
        options: GenerationOptions? = nil
    ) async throws -> String {
        let session = createSession(instructions: instructions)
        let text = try await generateText(session: session, prompt: prompt, options: options)
        return strippingLeadingCommentaryLine(from: text)
    }

    /// Drop a first line like "Here is the text:" that a model sometimes adds
    /// before the actual content when it is answering as free text rather than
    /// through the schema that would otherwise forbid commentary.
    private static func strippingLeadingCommentaryLine(from text: String) -> String {
        guard let newlineIndex = text.firstIndex(of: "\n") else { return text }
        let firstLine = text[text.startIndex..<newlineIndex].trimmingCharacters(in: .whitespaces)
        guard firstLine.hasSuffix(":") else { return text }
        return text[text.index(after: newlineIndex)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Session Recovery

    /// Recover from context window exceeded error by creating a new session with condensed transcript
    /// - Parameters:
    ///   - previousSession: The session that exceeded context window
    ///   - keepLastEntries: Number of last entries to keep (default: 1)
    /// - Returns: A new session with condensed transcript
    static func recoverSession(
        from previousSession: LanguageModelSession,
        keepLastEntries: Int = 1
    ) -> LanguageModelSession {
        let transcript = previousSession.transcript
        let allEntries = Array(transcript) 
        var condensedEntries = [Transcript.Entry]()

        // Always keep the first entry (instructions)
        if let firstEntry = allEntries.first {
            condensedEntries.append(firstEntry)

            // Keep the specified number of last entries
            if allEntries.count > 1 {
                let startIndex = max(1, allEntries.count - keepLastEntries)
                let lastEntries = Array(allEntries[startIndex...])
                condensedEntries.append(contentsOf: lastEntries)
            }
        }

        let condensedTranscript = Transcript(entries: condensedEntries)
        return LanguageModelSession(transcript: condensedTranscript)
    }

    // MARK: - Language Support

    /// Check if the current locale is supported by Foundation Models.
    ///
    /// Uses the framework's own `supportsLocale`, which accounts for regional
    /// fallbacks — a locale like `en-CA` that is not itself a member of
    /// `supportedLanguages` but falls back to a supported base language — where
    /// testing set membership directly would wrongly reject it.
    /// - Returns: True if the current locale is supported
    static func isCurrentLocaleSupported() -> Bool {
        permissiveModel.supportsLocale()
    }

    /// Get all supported languages
    /// - Returns: Array of supported languages
    static func getSupportedLanguages() -> [Locale.Language] {
        return Array(permissiveModel.supportedLanguages)
    }

    // MARK: - Model Availability

    /// Why Apple Intelligence cannot answer right now, or nil when it can.
    ///
    /// Distinct from the language check above: a supported locale on a Mac where
    /// Apple Intelligence was never turned on, or is still downloading its model,
    /// would otherwise fail the same way a real request does — with whatever
    /// generic error the SDK happens to throw once the request is already under
    /// way, rather than a message that explains why up front.
    static func unavailabilityReason() -> String? {
        switch permissiveModel.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "This Mac does not support Apple Intelligence."
            case .appleIntelligenceNotEnabled:
                return "Turn on Apple Intelligence in System Settings → Apple Intelligence & Siri."
            case .modelNotReady:
                return "Apple Intelligence is still downloading its model. Try again shortly."
            @unknown default:
                return "Apple Intelligence is not available right now."
            }
        }
    }

    // MARK: - Generation Options Helpers

    /// Create generation options for deterministic output
    /// - Returns: GenerationOptions configured for greedy sampling
    static func deterministicOptions() -> GenerationOptions {
        return GenerationOptions(sampling: .greedy)
    }

    /// Create generation options with custom temperature
    /// - Parameter temperature: Temperature value (0.0 for deterministic, higher for more creative)
    /// - Returns: GenerationOptions with specified temperature
    static func temperatureOptions(_ temperature: Double) -> GenerationOptions {
        return GenerationOptions(temperature: temperature)
    }

    // MARK: - Convenience Methods

    /// Simple text generation with automatic session creation and error handling
    /// - Parameters:
    ///   - prompt: The user prompt
    ///   - instructions: System instructions (optional)
    ///   - deterministic: Whether to use deterministic generation (default: false)
    /// - Returns: Generated text
    /// - Throws: FoundationModelsError
    static func quickGenerate(
        prompt: String,
        instructions: String? = nil,
        deterministic: Bool = false
    ) async throws -> String {
        let session = LanguageModelSession(
            model: permissiveModel,
            instructions: instructions ?? "You are a helpful assistant."
        )

        let options = deterministic ? deterministicOptions() : nil
        return try await generateText(session: session, prompt: prompt, options: options)
    }
}

// MARK: - Error Types

/// Custom error types for Foundation Models operations
enum FoundationModelsError: LocalizedError {
    case contextWindowExceeded
    case unsupportedLanguage
    case noContent
    case guardrailViolation
    case generationFailed(any Error)

    var errorDescription: String? {
        switch self {
        case .contextWindowExceeded:
            return "The conversation has become too long. Please start a new session."
        case .unsupportedLanguage:
            return "The current language or locale is not supported by Foundation Models."
        case .noContent:
            return "No content available to enhance. Please record or add some text first."
        case .guardrailViolation:
            return "The on-device model refused to process this content due to Apple's built-in safety restrictions. Your original transcription is preserved — try the Raw (No Processing) prompt instead."
        case .generationFailed(let error):
            return "Failed to generate content: \(error.localizedDescription)"
        }
    }
}

// MARK: - Session State Manager

/// Helper class for managing multiple sessions and their state
@MainActor
class FoundationModelsSessionManager {
    private var sessions: [String: LanguageModelSession] = [:]

    /// Get or create a session with the given ID
    /// - Parameters:
    ///   - id: Unique identifier for the session
    ///   - instructions: Instructions for new sessions
    /// - Returns: The session for the given ID
    func getSession(id: String, instructions: String? = nil) -> LanguageModelSession {
        if let existingSession = sessions[id] {
            return existingSession
        }

        let newSession = LanguageModelSession(
            model: FoundationModelsHelper.permissiveModel,
            instructions: instructions ?? "You are a helpful assistant."
        )
        sessions[id] = newSession
        return newSession
    }

    /// Remove a session
    /// - Parameter id: The session ID to remove
    func removeSession(id: String) {
        sessions.removeValue(forKey: id)
    }

    /// Handle context window exceeded by creating a new session
    /// - Parameters:
    ///   - id: The session ID
    ///   - keepLastEntries: Number of last entries to keep
    /// - Returns: The new recovered session
    func recoverSession(id: String, keepLastEntries: Int = 1) -> LanguageModelSession? {
        guard let oldSession = sessions[id] else { return nil }

        let newSession = FoundationModelsHelper.recoverSession(
            from: oldSession,
            keepLastEntries: keepLastEntries
        )
        sessions[id] = newSession
        return newSession
    }

    /// Clear all sessions
    func clearAllSessions() {
        sessions.removeAll()
    }

    /// Get the number of active sessions
    var sessionCount: Int {
        return sessions.count
    }
}
