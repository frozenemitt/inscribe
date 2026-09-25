import AppIntents
import os
import SwiftData
import Foundation

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - Quick Transcribe Intent

/// Quick transcription intent - records for a specified duration and returns text
struct QuickTranscribeIntent: AppIntent {
    static let title: LocalizedStringResource = "Quick Transcribe"
    static let description = IntentDescription("Record your voice and get it transcribed.")

    static let openAppWhenRun: Bool = false

    @Parameter(title: "Duration", description: "Recording duration in seconds (5-120)", default: 15)
    var duration: Int

    /// Picked from the list rather than typed. A typed name had to match exactly, and
    /// a typo silently skipped the AI pass.
    @Parameter(title: "AI Prompt", description: "Optional AI processing prompt")
    var prompt: PromptEntity?

    @Parameter(title: "Copy to Clipboard", default: true)
    var copyToClipboard: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Transcribe for \(\.$duration) seconds") {
            \.$prompt
            \.$copyToClipboard
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        // Validate duration
        let recordingDuration = min(max(duration, 5), 120)

        // The app's engine, not a new one: a second engine records over whatever the
        // app is already doing, because the guard that refuses that is instance state.
        let engine = TranscriptionEngine.shared

        // Load settings for feedback preferences
        let settings = AppSettings()

        // Whether this run's own recording started. Only that one may be cancelled on
        // the way out: a start refused as busy belongs to someone else's session, and
        // cancelling it threw away a dictation the user was in the middle of.
        var started = false

        do {
            // The same microphone, vocabulary and text rules the hotkey uses. A
            // shortcut that transcribed differently from the menu bar was the same
            // app answering the same question two ways.
            //
            // Recorded as a shortcut, not as a dictation, so the hotkey, Escape and the
            // menu bar leave it alone.
            try await engine.startRecording(
                owner: .shortcut,
                contextualStrings: settings.vocabularyHints,
                inputDeviceUID: settings.inputDeviceUID
            )
            started = true

            // Sounded once capture is live, as the hotkey does, so a refused start is
            // not announced as a recording.
            AudioFeedbackService.shared.playIfEnabled(.recordingStarted, settings: settings)
            #if os(iOS)
            AudioFeedbackService.shared.playStartHaptic()

            // Start Live Activity
            await LiveActivityManager.shared.startRecordingActivity()
            #endif

            // Record for specified duration
            try await Task.sleep(nanoseconds: UInt64(recordingDuration) * 1_000_000_000)

            // Play stop sound
            AudioFeedbackService.shared.playIfEnabled(.recordingStopped, settings: settings)
            #if os(iOS)
            AudioFeedbackService.shared.playStopHaptic()

            // Transition Live Activity to processing
            LiveActivityManager.shared.transitionToProcessing()
            #endif

            // Stop and get transcription
            let transcription = TextProcessor.process(
                try await engine.stopRecording(owner: .shortcut),
                replacements: settings.wordReplacements
            )

            guard !transcription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                #if os(iOS)
                await LiveActivityManager.shared.endActivity()
                #endif
                return .result(
                    value: "",
                    dialog: "No speech was detected. Please try again."
                )
            }

            // Apply AI processing if requested, falling back to raw transcript on failure
            var finalText = transcription
            var aiFailureReason: String?
            var appliedPrompt: String?
            if let prompt {
                let promptConfig = PromptConfiguration()
                let aiProcessor = AIProcessor(promptConfiguration: promptConfig)

                if promptConfig.prompt(withId: prompt.id) != nil {
                    do {
                        finalText = try await aiProcessor.process(text: transcription, promptId: prompt.id)
                        appliedPrompt = prompt.name
                    } catch {
                        Log.intents.error("AI processing failed, using raw transcript: \(error, privacy: .public)")
                        finalText = transcription
                        aiFailureReason = "AI processing failed."
                    }
                } else {
                    // A prompt deleted since the shortcut was made. Reported rather than
                    // thrown: the recording is already spent, and the transcript is
                    // still worth handing back.
                    Log.intents.error("The shortcut's prompt no longer exists")
                    aiFailureReason = "The prompt \"\(prompt.name)\" no longer exists."
                }
            }

            // Copy to clipboard
            if copyToClipboard {
                ClipboardService.copy(finalText)
            }

            recordHistory(finalText, raw: transcription, promptName: appliedPrompt, settings: settings)

            // End Live Activity and show notification
            #if os(iOS)
            await LiveActivityManager.shared.endActivity()
            #endif

            AudioFeedbackService.shared.playIfEnabled(.processingComplete, settings: settings)

            if let aiFailureReason {
                NotificationService.shared.showAIProcessingFailedIfEnabled(
                    characterCount: finalText.count,
                    errorDetail: "\(aiFailureReason) Raw transcription was used instead.",
                    settings: settings
                )
            } else {
                NotificationService.shared.showTranscriptionCompleteIfEnabled(
                    characterCount: finalText.count,
                    destination: copyToClipboard ? "Clipboard" : nil,
                    settings: settings
                )
            }

            let dialog = if let aiFailureReason {
                copyToClipboard
                    ? "\(aiFailureReason) Raw transcription copied to clipboard."
                    : "\(aiFailureReason) Raw transcription returned."
            } else {
                copyToClipboard
                    ? "Transcription complete and copied to clipboard."
                    : "Transcription complete."
            }

            return .result(
                value: finalText,
                dialog: IntentDialog(stringLiteral: dialog)
            )

        } catch {
            // Shortcuts cancelling the run, or the system killing it for going past
            // its time limit, throws out of the sleep above. Without this the
            // microphone stays live with nothing watching it — no watchdog was armed,
            // because the coordinator was never part of this.
            if started {
                engine.cancelRecording(owner: .shortcut)
            }

            #if os(iOS)
            await LiveActivityManager.shared.endActivity()
            AudioFeedbackService.shared.playErrorHaptic()
            #endif
            AudioFeedbackService.shared.playIfEnabled(.error, settings: settings)
            throw error
        }
    }
}

// MARK: - Record Transcription Intent

/// Full featured recording intent with customizable duration and AI processing
struct RecordTranscriptionIntent: AppIntent {
    static let title: LocalizedStringResource = "Record and Transcribe"
    static let description = IntentDescription("Record audio, transcribe it, and optionally process with AI.")

    static let openAppWhenRun: Bool = false

    @Parameter(title: "Duration", description: "Recording duration in seconds", default: 30)
    var duration: Int

    @Parameter(title: "Process with AI", description: "Apply AI processing to the transcription", default: true)
    var processWithAI: Bool

    @Parameter(title: "AI Action", description: "What to do with the transcription")
    var aiAction: AIActionEnum?

    @Parameter(title: "Copy to Clipboard", default: true)
    var copyToClipboard: Bool

    static var parameterSummary: some ParameterSummary {
        When(\.$processWithAI, .equalTo, true) {
            Summary("Record for \(\.$duration) seconds and \(\.$aiAction)") {
                \.$copyToClipboard
            }
        } otherwise: {
            Summary("Record for \(\.$duration) seconds") {
                \.$copyToClipboard
            }
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let recordingDuration = min(max(duration, 5), 300)

        // The app's engine, not a new one: a second engine records over whatever the
        // app is already doing, because the guard that refuses that is instance state.
        let engine = TranscriptionEngine.shared
        let settings = AppSettings()
        var started = false

        do {
            try await engine.startRecording(
                owner: .shortcut,
                contextualStrings: settings.vocabularyHints,
                inputDeviceUID: settings.inputDeviceUID
            )
            started = true
            // The same sounds the hotkey and the other action make. This one used to
            // record in silence, with nothing to say when to start talking.
            AudioFeedbackService.shared.playIfEnabled(.recordingStarted, settings: settings)
            try await Task.sleep(nanoseconds: UInt64(recordingDuration) * 1_000_000_000)
            AudioFeedbackService.shared.playIfEnabled(.recordingStopped, settings: settings)
            let transcription = TextProcessor.process(
                try await engine.stopRecording(owner: .shortcut),
                replacements: settings.wordReplacements
            )

            guard !transcription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .result(value: "", dialog: "No speech detected.")
            }

            var finalText = transcription
            var dialogPrefix = "Transcription"
            var aiProcessingFailed = false
            var appliedAction: String?

            // "Process with AI" with no action picked used to skip the AI pass without
            // a word. It runs the default clean-up instead.
            if processWithAI {
                let action = aiAction ?? .cleanup
                let promptConfig = PromptConfiguration()
                let aiProcessor = AIProcessor(promptConfiguration: promptConfig)

                do {
                    finalText = try await aiProcessor.quickProcess(text: transcription, action: action.toQuickAction)
                    dialogPrefix = action.rawValue
                    if action != .raw { appliedAction = action.rawValue }
                } catch {
                    Log.intents.error("AI processing failed, using raw transcript: \(error, privacy: .public)")
                    finalText = transcription
                    aiProcessingFailed = true
                }
            }

            if copyToClipboard {
                ClipboardService.copy(finalText)
            }

            recordHistory(
                finalText,
                raw: transcription,
                promptName: appliedAction,
                settings: settings
            )

            let dialog = if aiProcessingFailed {
                copyToClipboard
                    ? "AI processing failed. Raw transcription copied to clipboard."
                    : "AI processing failed. Raw transcription returned."
            } else {
                copyToClipboard
                    ? "\(dialogPrefix) complete and copied to clipboard."
                    : "\(dialogPrefix) complete."
            }

            return .result(value: finalText, dialog: IntentDialog(stringLiteral: dialog))

        } catch {
            // Same reason as the other intent: a cancelled run must not leave the
            // microphone recording, and must not cancel a session that is not its own.
            if started {
                engine.cancelRecording(owner: .shortcut)
            }
            AudioFeedbackService.shared.playIfEnabled(.error, settings: settings)
            throw error
        }
    }
}

// MARK: - AI Action Enum

/// App Intent enum for AI processing actions
enum AIActionEnum: String, AppEnum {
    case cleanup = "Clean up"
    case summarize = "Summarize"
    case makeFormal = "Make formal"
    case makeCasual = "Make casual"
    case fixPunctuation = "Fix punctuation"
    case raw = "No processing"

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "AI Action")

    static let caseDisplayRepresentations: [AIActionEnum: DisplayRepresentation] = [
        .cleanup: "Clean up grammar",
        .summarize: "Summarize as bullets",
        .makeFormal: "Make formal",
        .makeCasual: "Make casual",
        .fixPunctuation: "Fix punctuation only",
        .raw: "No AI processing"
    ]

    var toQuickAction: AIProcessor.QuickAction {
        switch self {
        case .cleanup: return .cleanup
        case .summarize: return .summarize
        case .makeFormal: return .makeFormal
        case .makeCasual: return .makeCasual
        case .fixPunctuation: return .fixPunctuation
        case .raw: return .raw
        }
    }
}

// MARK: - Prompt Query

/// Entity for selecting prompts in Shortcuts
struct PromptEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "AI Prompt")

    var id: UUID
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    static let defaultQuery = PromptQuery()
}

struct PromptQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [PromptEntity] {
        let config = PromptConfiguration()
        return identifiers.compactMap { id in
            guard let prompt = config.prompt(withId: id) else { return nil }
            return PromptEntity(id: prompt.id, name: prompt.name)
        }
    }

    func suggestedEntities() async throws -> [PromptEntity] {
        let config = PromptConfiguration()
        return config.prompts.map { PromptEntity(id: $0.id, name: $0.name) }
    }
}

// MARK: - History

/// Keep what a shortcut dictated, the same as the hotkey does.
///
/// A transcript that exists only in a Shortcuts result is gone the moment the user
/// dismisses it, which is exactly the case history exists for.
@MainActor
private func recordHistory(
    _ text: String,
    raw: String,
    promptName: String?,
    settings: AppSettings
) {
    #if os(macOS)
    DictationHistory.record(
        text: text,
        rawText: raw == text ? nil : raw,
        destination: "Shortcuts",
        promptName: promptName,
        settings: settings,
        in: ScribeApp.modelContainer.mainContext
    )
    #endif
}
