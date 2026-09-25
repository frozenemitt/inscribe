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

    /// How many AI requests are currently in flight.
    ///
    /// A meeting summary and a dictation both go through this processor, and each
    /// builds its own `LanguageModelSession` — there is no shared state a second
    /// request could corrupt, so unlike a true single-session design there is no
    /// reason a summary running in the background should make a concurrent
    /// dictation fail. Kept as a count rather than a flag so `isProcessing` below
    /// still reads correctly for as long as anything at all is running.
    private(set) var activeRequestCount = 0

    /// Whether any AI request is currently running, for the UI.
    var isProcessing: Bool { activeRequestCount > 0 }

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
    /// Keyed on the instructions text as well as the prompt id: editing a prompt
    /// keeps its id, and a session already warmed with the old wording would
    /// otherwise run those stale instructions on the next dictation.
    private var warmSession: LanguageModelSession?
    private var warmPromptId: UUID?
    private var warmInstructions: String?

    // MARK: - Configuration

    let promptConfiguration: PromptConfiguration

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
    /// - Parameter onPartial: Called with the rewrite so far, each time it grows, for
    ///   a caller that shows it while the model is still writing.
    func process(
        text: String,
        promptId: UUID? = nil,
        surroundingText: String? = nil,
        onPartial: (@MainActor (String) -> Void)? = nil
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
            surroundingText: surroundingText,
            onPartial: onPartial
        )
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
        guard warmPromptId != prompt.id || warmInstructions != prompt.systemPrompt else { return }

        let session = FoundationModelsHelper.createSession(instructions: prompt.systemPrompt)
        session.prewarm()
        warmSession = session
        warmPromptId = prompt.id
        warmInstructions = prompt.systemPrompt
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

    /// Warm the loaded session on the words already confirmed, while more are spoken.
    ///
    /// The request that follows the key release starts with exactly this text — the
    /// same template, context and transcript, up to where the recognizer has got to —
    /// so the model has already read most of it when the request arrives. Measured
    /// saving: 0.2–0.3 s on a 733-character dictation with four fifths of it warmed.
    /// Writing the answer is the rest of the wait, and nothing here shortens it.
    ///
    /// Does nothing when no session was warmed at the start, or when it was warmed for
    /// a different prompt.
    func warmPrefix(promptId: UUID?, transcriptSoFar: String, surroundingText: String?) {
        guard let warmSession, let prompt = resolvedPrompt(for: promptId),
              warmPromptId == prompt.id, warmInstructions == prompt.systemPrompt else { return }

        let full = Self.userPrompt(for: prompt, text: transcriptSoFar, surroundingText: surroundingText)
        let closing = "\n</transcription>"
        let prefix = full.hasSuffix(closing) ? String(full.dropLast(closing.count)) : full
        warmSession.prewarm(promptPrefix: FoundationModels.Prompt(prefix))
    }

    /// Forget a warmed session that will not be used.
    func discardPrewarm() {
        warmSession = nil
        warmPromptId = nil
        warmInstructions = nil
    }

    // MARK: - Private Implementation

    private func processWithPrompt(
        text: String,
        prompt: Prompt,
        surroundingText: String? = nil,
        onPartial: (@MainActor (String) -> Void)? = nil
    ) async throws -> String {
        guard !text.isEmpty else {
            throw AIProcessorError.emptyInput
        }

        // Check language support
        guard FoundationModelsHelper.isCurrentLocaleSupported() else {
            throw AIProcessorError.languageNotSupported
        }

        // Fail with a clear reason before spending any time on a session that can
        // never answer, rather than letting the request reach the model and come
        // back with whatever generic error the SDK happens to throw.
        if let reason = FoundationModelsHelper.unavailabilityReason() {
            throw AIProcessorError.appleIntelligenceUnavailable(reason)
        }

        activeRequestCount += 1
        lastError = nil

        defer {
            activeRequestCount -= 1
        }

        Log.ai.notice("Processing with prompt: \(prompt.name)")

        // The session warmed while this was being spoken, if it was warmed for this
        // prompt with its current instructions. Taken rather than borrowed: a
        // session carries its own transcript, so the next dictation gets a fresh one.
        let session: LanguageModelSession
        if let warmSession, warmPromptId == prompt.id, warmInstructions == prompt.systemPrompt {
            session = warmSession
        } else {
            session = FoundationModelsHelper.createSession(instructions: prompt.systemPrompt)
        }
        discardPrewarm()

        let userPrompt = Self.userPrompt(for: prompt, text: text, surroundingText: surroundingText)

        // Use per-prompt generation settings with structured output
        let options = prompt.generationOptions()

        do {
            let result: TranscriptionResult
            if let onPartial {
                let started = ContinuousClock.now
                var reportedFirst = false
                result = try await FoundationModelsHelper.streamTranscription(
                    session: session,
                    prompt: userPrompt,
                    options: options
                ) { partial in
                    if !reportedFirst {
                        reportedFirst = true
                        let ms = Int((ContinuousClock.now - started) / .milliseconds(1))
                        Log.ai.notice("First rewritten words after \(ms, privacy: .public) ms")
                    }
                    onPartial(partial)
                }
            } else {
                result = try await FoundationModelsHelper.generateStructured(
                    session: session,
                    prompt: userPrompt,
                    generating: TranscriptionResult.self,
                    options: options
                )
            }
            return keepingWords(of: text, in: try cleaned(result.text), for: prompt)

        } catch FoundationModelsError.contextWindowExceeded {
            lastError = .contextWindowExceeded
            throw AIProcessorError.contextWindowExceeded
        } catch FoundationModelsError.unsupportedLanguage {
            lastError = .languageNotSupported
            throw AIProcessorError.languageNotSupported
        } catch FoundationModelsError.guardrailViolation {
            // Guided generation doesn't benefit from the permissive guardrail level
            // (see the comment on `permissiveModel`), so before giving up, ask once
            // more for plain text, which does.
            do {
                let retried = try await FoundationModelsHelper.generateTextAfterGuardrailViolation(
                    instructions: prompt.systemPrompt,
                    prompt: userPrompt,
                    options: options
                )
                let result = keepingWords(of: text, in: try cleaned(retried), for: prompt)
                Log.ai.notice("Recovered from a guardrail violation by asking for plain text")
                return result
            } catch {
                lastError = .guardrailViolation
                throw AIProcessorError.guardrailViolation
            }
        } catch let error as AIProcessorError {
            lastError = .processingFailed(error.localizedDescription)
            throw error
        } catch {
            lastError = .processingFailed(error.localizedDescription)
            throw AIProcessorError.processingFailed(error.localizedDescription)
        }
    }

    /// Strip tags the model sometimes echoes back, and fail loudly on an empty
    /// result rather than handing the caller nothing to paste. The raw transcript
    /// exists nowhere else once this returns, so silence here would lose the
    /// dictation outright rather than merely skip the rewrite.
    /// The request the model receives: the template, the transcript, and any
    /// surrounding text.
    ///
    /// One function for the real request and for warming, so the warmed prefix is the
    /// request's own opening, character for character. Any difference and the warming
    /// buys nothing.
    private static func userPrompt(for prompt: Prompt, text: String, surroundingText: String?) -> String {
        let request = prompt.apply(to: text)

        // Prepended, and fenced off in its own tags, so the model treats it as
        // background rather than as more text to rewrite. Without the fencing the
        // model tends to "clean up" the surrounding document too and hand it back.
        guard let surroundingText, !surroundingText.isEmpty else { return request }
        return """
            <context>
            The user is dictating into a text field that already contains the \
            following. Use it only to match tone, terminology and the thread of \
            the conversation. Do not repeat it, summarise it, or include any of \
            it in your reply.

            \(surroundingText)
            </context>

            \(request)
            """
    }

    /// Hold a prompt that keeps the speaker's words to it; see `WordGuard`.
    private func keepingWords(of said: String, in rewrite: String, for prompt: Prompt) -> String {
        guard prompt.keepsWords else { return rewrite }
        let outcome = WordGuard.apply(said: said, rewrite: rewrite)
        if outcome.restored > 0 || outcome.removed > 0 {
            Log.ai.notice("Word check put back \(outcome.restored, privacy: .public) words and took out \(outcome.removed, privacy: .public) added ones")
        }
        return outcome.text
    }

    private func cleaned(_ text: String) throws -> String {
        let cleaned = text
            .replacingOccurrences(of: "<transcription>", with: "")
            .replacingOccurrences(of: "</transcription>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else {
            throw AIProcessorError.emptyResult
        }

        Log.ai.notice("Processing complete, result length: \(cleaned.count, privacy: .public)")
        return cleaned
    }

    // MARK: - Model Information

    /// Why Apple Intelligence cannot answer right now, or nil when it can.
    ///
    /// For Settings, so a user who has switched AI processing on but never turned
    /// on Apple Intelligence — or whose Mac cannot run it at all — sees why, rather
    /// than discovering it as a mysterious failure the first time they dictate.
    static var unavailabilityReason: String? {
        FoundationModelsHelper.unavailabilityReason()
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
    case emptyResult
    case languageNotSupported
    case appleIntelligenceUnavailable(String)
    case contextWindowExceeded
    case guardrailViolation
    case processingFailed(String)

    var errorDescription: String? {
        switch self {
        case .promptNotFound:
            return "The selected prompt could not be found"
        case .emptyInput:
            return "No text to process"
        case .emptyResult:
            return "The AI returned no text, so nothing was changed."
        case .languageNotSupported:
            return "The current language is not supported for AI processing"
        case .appleIntelligenceUnavailable(let reason):
            return reason
        case .contextWindowExceeded:
            return "The text is too long to process"
        case .guardrailViolation:
            return "The on-device model refused to process this content due to Apple's safety restrictions. Your original transcription is preserved — try the Raw (No Processing) prompt instead."
        case .processingFailed(let reason):
            return "Processing failed: \(reason)"
        }
    }
}
