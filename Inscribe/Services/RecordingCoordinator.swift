import Foundation
import os
import Observation
import SwiftData

#if os(macOS)
import AppKit
#endif

/// Owns one recording from hotkey press to delivered text.
///
/// The menu bar button and the global hotkey both run this, so feedback sounds,
/// notifications, the AI fallback and the output decision stay in one place.
@MainActor
@Observable
final class RecordingCoordinator {

    // MARK: - Dependencies

    private let engine: TranscriptionEngine
    private let aiProcessor: AIProcessor
    private let settings: AppSettings

    // MARK: - State

    /// Skip the AI pass for the next recording only. Reset once it is consumed.
    var skipAIOnce = false

    /// Where the last result went, for the menu bar to report.
    private(set) var lastDestination: String?

    /// Set by the app once the store is open, so finished dictations can be kept.
    var modelContext: ModelContext?

    #if os(macOS)
    private let overlay: DictationOverlayController

    /// Polls the engine while recording so the overlay tracks the live text.
    ///
    /// A timer rather than observation: the transcriber revises its volatile text many
    /// times a second, and redrawing a window on every revision is wasteful. It runs at
    /// twenty a second for the level band's sake; the text is only handed over when it
    /// has actually changed, so the cost of the faster tick is one number.
    private var overlayTicker: Task<Void, Never>?
    #endif

    #if os(macOS)
    /// Whoever was frontmost when recording began — the app the text belongs to.
    private var targetApp: NSRunningApplication?

    /// Overrides for the target app, resolved once at the start of the recording.
    ///
    /// Pinned at the start rather than read at delivery: the user may have switched
    /// apps while talking, and the settings that applied when they began are the ones
    /// they were thinking of.
    private var activeProfile: AppProfile?
    #endif

    /// Stops a recording that has run past `settings.maxRecordingSeconds`.
    private var maxDurationTask: Task<Void, Never>?

    /// The start still coming up, if there is one.
    ///
    /// Bringing the engine up takes a moment, and a push-to-talk tap can be shorter
    /// than that. The release waits here instead of being dropped, which is what used
    /// to leave the microphone live with nobody holding the key.
    private var startTask: Task<Void, Never>?

    /// The engine teardown still finishing, if there is one.
    ///
    /// Only the engine's part, not the AI pass that follows it: the next dictation
    /// should wait about a tenth of a second for the microphone, not several seconds
    /// for a model to answer.
    private var stopTask: Task<String, any Error>?

    /// True from the moment the engine lets go until the text has landed.
    ///
    /// The AI pass can take seconds, and the text belongs to the app that was
    /// frontmost when it was spoken. A second dictation started in the meantime would
    /// have the first one's words activated into the first one's app, pulling focus
    /// away from the sentence being spoken right now.
    private var isDelivering = false

    /// True only while *this* coordinator's dictation is running.
    ///
    /// Not `engine.isRecording`: the engine is shared with meeting mode, and a meeting
    /// would otherwise look like a dictation to every guard here.
    var isRecording: Bool { engine.owner == .dictation && engine.isRecording }
    var isProcessing: Bool { aiProcessor.isProcessing }

    // MARK: - Initialization

    init(engine: TranscriptionEngine, aiProcessor: AIProcessor, settings: AppSettings) {
        self.engine = engine
        self.aiProcessor = aiProcessor
        self.settings = settings
        #if os(macOS)
        self.overlay = DictationOverlayController(settings: settings)
        #endif
    }

    #if os(macOS)
    /// Put the overlay back at the bottom of the screen, for the settings screen.
    func resetOverlayPosition() {
        overlay.resetPosition()
    }
    #endif

    // MARK: - Resolved Settings

    /// The prompt to run, honouring any per-app override.
    private var effectivePromptId: UUID? {
        #if os(macOS)
        if let promptId = activeProfile?.promptId { return promptId }
        #endif
        return settings.selectedPromptId
    }

    #if os(macOS)
    /// The output mode to use, honouring any per-app override.
    private var effectiveOutputMode: OutputMode {
        if let raw = activeProfile?.outputModeRaw, let mode = OutputMode(rawValue: raw) {
            return mode
        }
        return settings.outputMode
    }

    /// Whether to press Return afterwards, honouring any per-app override.
    private var effectiveAutoSubmit: Bool {
        activeProfile?.autoSubmit ?? settings.autoSubmitAfterInsert
    }
    #endif

    // MARK: - Recording Control

    func toggle() async {
        // A second press during the start is the user asking to stop, so let the
        // session finish coming up and then end it, rather than reading the
        // half-built state as "not recording" and opening a second microphone.
        if let startTask { await startTask.value }

        if isRecording {
            await stopAndProcess()
        } else {
            await start()
        }
    }

    func start() async {
        // Let the previous dictation hand the engine back before claiming it. Without
        // this the new session cleared the old one's transcript out from under it and
        // both sets of words were lost.
        if let stopTask { _ = try? await stopTask.value }

        guard !isDelivering else {
            Log.dictation.notice("Still delivering the last dictation")
            AudioFeedbackService.shared.playIfEnabled(.error, settings: settings)
            return
        }

        // Refuse to start over anyone's session, including a meeting's, and including
        // one that is still coming up.
        guard !engine.isBusy else { return }

        let task = Task { await self.begin() }
        startTask = task
        await task.value
        startTask = nil
    }

    private func begin() async {

        #if os(macOS)
        // Captured before we touch anything, so a menu bar click that steals focus
        // does not redirect the text to Inscribe itself.
        targetApp = NSWorkspace.shared.frontmostApplication
        activeProfile = settings.profile(forBundleIdentifier: targetApp?.bundleIdentifier)

        if let activeProfile {
            Log.dictation.notice("Using profile for \(activeProfile.appName, privacy: .public)")
        }

        // Chromium-based apps need to be told to build an accessibility tree, and it
        // takes them a moment. Asking now means it is ready by the time we deliver.
        TextInsertionService.prepareForInsertion(into: targetApp)
        #endif

        do {
            try await engine.startRecording(
                owner: .dictation,
                contextualStrings: settings.vocabularyHints,
                inputDeviceUID: settings.inputDeviceUID,
                publishesSpectrum: settings.showDictationOverlay
            )
        } catch {
            AudioFeedbackService.shared.playIfEnabled(.error, settings: settings)
            NotificationService.shared.showErrorIfEnabled(error.localizedDescription, settings: settings)
            Log.dictation.error("Failed to start: \(error, privacy: .public)")
            return
        }

        // Load the model while the user is still speaking. It has to be in memory
        // before it can answer, and that load used to begin only once they had
        // finished — seconds of waiting bolted onto seconds of talking.
        if settings.aiEnabled, !skipAIOnce {
            aiProcessor.prewarm(promptId: effectivePromptId)
        }

        // Sounded only once capture is live, so the user does not talk over the gap.
        AudioFeedbackService.shared.playIfEnabled(.recordingStarted, settings: settings)
        startMaxDurationWatchdog()

        #if os(macOS)
        if settings.showDictationOverlay {
            overlay.show()
            startOverlayTicker()
        }
        #endif
        Log.dictation.notice("Recording started")
    }

    /// Stop, transcribe, optionally run the AI pass, then deliver the text.
    func stopAndProcess() async {
        // A release that lands while the engine is still coming up waits for it,
        // rather than being dropped and leaving the microphone running.
        if let startTask { await startTask.value }

        guard isRecording else { return }
        maxDurationTask?.cancel()
        maxDurationTask = nil

        AudioFeedbackService.shared.playIfEnabled(.recordingStopped, settings: settings)

        #if os(macOS)
        stopOverlayTicker()
        if settings.showDictationOverlay, settings.aiEnabled, !skipAIOnce {
            overlay.showProcessing()
        } else {
            overlay.hide()
        }
        #endif

        isDelivering = true
        defer { isDelivering = false }

        let rawTranscript: String
        let stop = Task { try await engine.stopRecording(owner: .dictation) }
        stopTask = stop
        do {
            rawTranscript = try await stop.value
            stopTask = nil
        } catch {
            stopTask = nil
            #if os(macOS)
            overlay.hide()
            #endif
            AudioFeedbackService.shared.playIfEnabled(.error, settings: settings)
            NotificationService.shared.showErrorIfEnabled(error.localizedDescription, settings: settings)
            Log.dictation.error("Error stopping: \(error, privacy: .public)")
            return
        }

        // Spoken punctuation and word replacements run before the AI pass, so a
        // corrected term reaches the model already spelled the way the user wants
        // rather than being "corrected" back.
        let transcript = TextProcessor.process(
            rawTranscript,
            replacements: settings.wordReplacements
        )

        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            #if os(macOS)
            overlay.hide()
            #endif
            skipAIOnce = false

            // A recognizer that failed and a room that was quiet used to look exactly
            // the same from outside: both ended in silence with no text. Say which.
            if let engineError = engine.error {
                AudioFeedbackService.shared.playIfEnabled(.error, settings: settings)
                NotificationService.shared.showErrorIfEnabled(
                    engineError.localizedDescription,
                    settings: settings
                )
                Log.dictation.error("Recognition failed: \(engineError, privacy: .public)")
            } else {
                AudioFeedbackService.shared.playIfEnabled(.error, settings: settings)
                NotificationService.shared.showErrorIfEnabled(
                    "Nothing was heard. Check the input device in Settings.",
                    settings: settings
                )
                Log.dictation.notice("Empty transcript, nothing to deliver")
            }
            return
        }

        let shouldUseAI = settings.aiEnabled && !skipAIOnce
        skipAIOnce = false

        guard shouldUseAI else {
            await deliver(transcript)
            recordHistory(text: transcript, rawText: nil)
            AudioFeedbackService.shared.playIfEnabled(.processingComplete, settings: settings)
            NotificationService.shared.showTranscriptionCompleteIfEnabled(
                characterCount: transcript.count,
                destination: lastDestination,
                settings: settings
            )
            return
        }

        // Read now rather than at delivery, and asked of the app the dictation was aimed
        // at: by the time the model answers the user may be looking at something else,
        // and the field we want is the one they were dictating into.
        var surroundingText: String?
        #if os(macOS)
        if settings.useSurroundingContext {
            surroundingText = TextInsertionService.focusedFieldContext(in: targetApp)
        }
        #endif

        AudioFeedbackService.shared.startProcessingLoopIfEnabled(settings: settings)

        let finalText: String
        do {
            finalText = try await aiProcessor.process(
                text: transcript,
                promptId: effectivePromptId,
                surroundingText: surroundingText
            )
            AudioFeedbackService.shared.stopProcessingLoop()
        } catch {
            // A failed AI pass must not cost the user their words.
            AudioFeedbackService.shared.stopProcessingLoop()
            Log.dictation.error("AI failed, delivering raw transcript: \(error, privacy: .public)")

            await deliver(transcript)
            recordHistory(text: transcript, rawText: nil)
            AudioFeedbackService.shared.playIfEnabled(.processingComplete, settings: settings)
            NotificationService.shared.showAIProcessingFailedIfEnabled(
                characterCount: transcript.count,
                errorDetail: error.localizedDescription,
                settings: settings
            )
            return
        }

        await deliver(finalText)
        recordHistory(text: finalText, rawText: transcript)
        AudioFeedbackService.shared.playIfEnabled(.processingComplete, settings: settings)
        NotificationService.shared.showTranscriptionCompleteIfEnabled(
            characterCount: finalText.count,
            destination: lastDestination,
            settings: settings
        )
    }

    /// Keep the finished dictation, so it survives landing in the wrong window.
    private func recordHistory(text: String, rawText: String?) {
        guard let modelContext else { return }

        let promptName = effectivePromptId.flatMap { id in
            aiProcessor.promptConfiguration.prompt(withId: id)?.name
        }

        DictationHistory.record(
            text: text,
            rawText: rawText,
            destination: lastDestination,
            promptName: promptName,
            settings: settings,
            in: modelContext
        )
    }

    /// Throw away an in-flight recording without producing any text.
    func cancel() async {
        if let startTask { await startTask.value }
        guard isRecording else { return }
        maxDurationTask?.cancel()
        maxDurationTask = nil

        #if os(macOS)
        stopOverlayTicker()
        overlay.hide()
        #endif

        engine.cancelRecording(owner: .dictation)
        aiProcessor.discardPrewarm()
        skipAIOnce = false
        lastDestination = nil
        AudioFeedbackService.shared.playIfEnabled(.recordingStopped, settings: settings)
        Log.dictation.notice("Recording cancelled")
    }

    // MARK: - Output

    /// Send finished text wherever the user's output setting says it goes.
    private func deliver(_ text: String) async {
        #if os(macOS)
        // Dismissed before insertion: the panel is borderless and non-activating, but
        // leaving it up while text lands is visual noise at the wrong moment.
        overlay.hide()

        switch effectiveOutputMode {
        case .clipboardOnly:
            ClipboardService.copy(text)
            lastDestination = "Clipboard"

        case .smartInsert:
            let outcome = await TextInsertionService.deliver(
                text,
                targetApp: targetApp,
                restoreClipboard: settings.restoreClipboardAfterPaste,
                autoSubmit: effectiveAutoSubmit,
                submitUsesShift: settings.useShiftReturnAfterInsert
            )
            switch outcome {
            case .inserted(let appName):
                lastDestination = appName
            case .copiedToClipboard:
                lastDestination = "Clipboard"
            }
        }
        #else
        if settings.copyToClipboardAutomatically {
            ClipboardService.copy(text)
            lastDestination = "Clipboard"
        }
        #endif
    }

    #if os(macOS)
    // MARK: - Overlay

    private func startOverlayTicker() {
        stopOverlayTicker()

        overlayTicker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isRecording else { return }
                self.overlay.update(
                    text: self.engine.currentTranscript + self.engine.volatileText,
                    spectrum: self.engine.spectrum
                )
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func stopOverlayTicker() {
        overlayTicker?.cancel()
        overlayTicker = nil
    }
    #endif

    // MARK: - Safety Cap

    /// Stop a recording that has outlived `settings.maxRecordingSeconds`.
    ///
    /// A hotkey whose key-up never arrives — a lost event, a hung app — would
    /// otherwise record until the disk filled.
    private func startMaxDurationWatchdog() {
        maxDurationTask?.cancel()

        let limit = max(30, settings.maxRecordingSeconds)
        maxDurationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(limit))
            guard !Task.isCancelled, let self, self.isRecording else { return }
            Log.dictation.notice("Hit the \(limit, privacy: .public)s cap, stopping")
            await self.stopAndProcess()
        }
    }
}
