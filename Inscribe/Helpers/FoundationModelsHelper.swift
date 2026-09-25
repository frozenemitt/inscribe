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

    /// Generate the rewritten transcript, handing each partial version to `onPartial`
    /// as it is written.
    ///
    /// Takes as long as asking for the whole answer at once — measured at 3.0–3.1 s
    /// either way for 733 characters — but the first words exist after about 0.7 s
    /// instead of at the end, so the panel can show them while the rest is written.
    static func streamTranscription(
        session: LanguageModelSession,
        prompt: String,
        options: GenerationOptions,
        onPartial: @MainActor (String) -> Void
    ) async throws -> TranscriptionResult {
        do {
            let stream = session.streamResponse(to: prompt, generating: TranscriptionResult.self, options: options)
            for try await snapshot in stream {
                if let partial = snapshot.content.text, !partial.isEmpty {
                    onPartial(partial)
                }
            }
            return try await stream.collect().content
        } catch {
            throw mapGenerationError(error)
        }
    }

    /// Translate whatever the framework threw into our own error type.
    ///
    /// The minimum target is macOS 27, where guardrail, context-window and language
    /// failures throw the top-level `LanguageModelError` rather than the older,
    /// now-deprecated `LanguageModelSession.GenerationError` — so only the new type
    /// needs mapping here.
    private static func mapGenerationError(_ error: any Error) -> FoundationModelsError {
        guard let error = error as? LanguageModelError else {
            return .generationFailed(error)
        }

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
