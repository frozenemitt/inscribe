import AppIntents
import Foundation

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - Quick Transcribe Intent

/// Quick transcription intent - records for a specified duration and returns text
struct QuickTranscribeIntent: AppIntent {
    static var title: LocalizedStringResource = "Quick Transcribe"
    static var description = IntentDescription("Record your voice and get it transcribed.")

    static var openAppWhenRun: Bool = false

    @Parameter(title: "Duration", description: "Recording duration in seconds (5-120)", default: 15)
    var duration: Int

    @Parameter(title: "AI Prompt", description: "Optional AI processing prompt")
    var promptName: String?

    @Parameter(title: "Copy to Clipboard", default: true)
    var copyToClipboard: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Transcribe for \(\.$duration) seconds") {
            \.$promptName
            \.$copyToClipboard
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        // Validate duration
        let recordingDuration = min(max(duration, 5), 120)

        // Create transcription engine
        let engine = TranscriptionEngine()

        // Load settings for feedback preferences
        let settings = AppSettings()

        do {
            // Play start sound and haptic
            AudioFeedbackService.shared.playIfEnabled(.recordingStarted, settings: settings)
            #if os(iOS)
            AudioFeedbackService.shared.playStartHaptic()

            // Start Live Activity
            LiveActivityManager.shared.startRecordingActivity()
            #endif

            // Start recording
            try await engine.startRecording()

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
            let transcription = try await engine.stopRecording()

            guard !transcription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                #if os(iOS)
                LiveActivityManager.shared.endActivity()
                #endif
                return .result(
                    value: "",
                    dialog: "No speech was detected. Please try again."
                )
            }

            // Apply AI processing if requested
            var finalText = transcription
            if let promptName = promptName, !promptName.isEmpty {
                let promptConfig = PromptConfiguration()
                let aiProcessor = AIProcessor(promptConfiguration: promptConfig)

                // Find prompt by name
                if let prompt = promptConfig.prompts.first(where: { $0.name.lowercased() == promptName.lowercased() }) {
                    finalText = try await aiProcessor.process(text: transcription, promptId: prompt.id)
                }
            }

            // Copy to clipboard
            if copyToClipboard {
                ClipboardService.copy(finalText)
            }

            // End Live Activity and show notification
            #if os(iOS)
            LiveActivityManager.shared.endActivity()
            #endif

            AudioFeedbackService.shared.playIfEnabled(.processingComplete, settings: settings)
            NotificationService.shared.showTranscriptionCompleteIfEnabled(
                characterCount: finalText.count,
                settings: settings
            )

            let dialog = copyToClipboard
                ? "Transcription complete and copied to clipboard."
                : "Transcription complete."

            return .result(
                value: finalText,
                dialog: IntentDialog(stringLiteral: dialog)
            )

        } catch {
            #if os(iOS)
            LiveActivityManager.shared.endActivity()
            AudioFeedbackService.shared.playErrorHaptic()
            #endif
            AudioFeedbackService.shared.playIfEnabled(.error, settings: settings)
            throw IntentError.message("Transcription failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Record Transcription Intent

/// Full featured recording intent with customizable duration and AI processing
struct RecordTranscriptionIntent: AppIntent {
    static var title: LocalizedStringResource = "Record and Transcribe"
    static var description = IntentDescription("Record audio, transcribe it, and optionally process with AI.")

    static var openAppWhenRun: Bool = false

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
        let engine = TranscriptionEngine()

        do {
            try await engine.startRecording()
            try await Task.sleep(nanoseconds: UInt64(recordingDuration) * 1_000_000_000)
            let transcription = try await engine.stopRecording()

            guard !transcription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .result(value: "", dialog: "No speech detected.")
            }

            var finalText = transcription
            var dialogPrefix = "Transcription"

            if processWithAI, let action = aiAction {
                let promptConfig = PromptConfiguration()
                let aiProcessor = AIProcessor(promptConfiguration: promptConfig)

                finalText = try await aiProcessor.quickProcess(text: transcription, action: action.toQuickAction)
                dialogPrefix = action.rawValue
            }

            if copyToClipboard {
                ClipboardService.copy(finalText)
            }

            let dialog = copyToClipboard
                ? "\(dialogPrefix) complete and copied to clipboard."
                : "\(dialogPrefix) complete."

            return .result(value: finalText, dialog: IntentDialog(stringLiteral: dialog))

        } catch {
            throw IntentError.message("Recording failed: \(error.localizedDescription)")
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

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "AI Action")

    static var caseDisplayRepresentations: [AIActionEnum: DisplayRepresentation] = [
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

// MARK: - Start/Stop Intents (for toggle behavior)

/// Intent to start recording (for use with Shortcuts automations)
struct StartRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Recording"
    static var description = IntentDescription("Start recording audio for transcription.")

    static var openAppWhenRun: Bool = true  // Opens app to show recording status

    @MainActor
    func perform() async throws -> some IntentResult {
        // This would need to integrate with a shared state manager
        // For now, we just open the app
        return .result()
    }
}

/// Intent to stop recording and get the result
struct StopRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Recording"
    static var description = IntentDescription("Stop recording and get the transcription.")

    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        // This would need to integrate with a shared state manager
        return .result(value: "")
    }
}

// MARK: - Prompt Query

/// Entity for selecting prompts in Shortcuts
struct PromptEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "AI Prompt")

    var id: UUID
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    static var defaultQuery = PromptQuery()
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
