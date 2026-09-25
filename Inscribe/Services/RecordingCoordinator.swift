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

    /// True from the moment a dictation starts coming up until it stops recording.
    ///
    /// What Escape should cancel. `isRecording` is false for the 70–470 ms the engine
    /// takes to start, and an Escape pressed then went to the app instead.
    var isCancellable: Bool {
        engine.owner == .dictation && (engine.phase == .starting || engine.phase == .recording)
    }

    /// The most recent app other than Inscribe to come to the front.
    ///
    /// A dictation started from the menu bar can find Inscribe itself frontmost, and
    /// the text belongs to the app the user was in before they clicked.
    #if os(macOS)
    @ObservationIgnored private var lastExternalApp: NSRunningApplication?
    @ObservationIgnored private var activationObserver: (any NSObjectProtocol)?
    #endif
    @ObservationIgnored private var interruptionObserver: (any NSObjectProtocol)?

    /// What the target field held when the dictation began, for the AI pass.
    ///
    /// Read at the start rather than at delivery: the request warmed while the user
    /// speaks has to open with the same text as the request sent at release, and the
    /// field has not changed in between, since nothing is pasted until the end.
    @ObservationIgnored private var surroundingText: String?

    /// Warms the AI session on the words confirmed so far, while recording.
    @ObservationIgnored private var prefixWarmer: Task<Void, Never>?

    /// Longest the AI pass may take before the raw transcript is delivered instead.
    ///
    /// Until the text lands, every press is refused as "still delivering", so a model
    /// that never answers would otherwise hold the hotkey until relaunch.
    private static let aiDeadline: Double = 20

    // MARK: - Initialization

    init(engine: TranscriptionEngine, aiProcessor: AIProcessor, settings: AppSettings) {
        self.engine = engine
        self.aiProcessor = aiProcessor
        self.settings = settings
        #if os(macOS)
        self.overlay = DictationOverlayController(settings: settings)
        lastExternalApp = NSWorkspace.shared.frontmostApplication
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            MainActor.assumeIsolated { self?.lastExternalApp = app }
        }
        #endif

        // A microphone that changes mid-dictation ends the capture. Deliver what was
        // heard up to that point rather than leave the key recording silence.
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: TranscriptionEngine.captureInterruptedNotification,
            object: engine,
            queue: .main
        ) { [weak self] note in
            guard (note.userInfo?["owner"] as? TranscriptionEngine.SessionOwner) == .dictation else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.stopAndProcess() }
            }
        }
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
        // One start at a time. A press, release and press queued behind a busy main
        // thread used to run two starts together, and the second tore down the first.
        guard startTask == nil else { return }

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
        // one that is still coming up. Said out loud: a silent refusal has the user
        // talking into nothing.
        guard !engine.isBusy else {
            Log.dictation.notice("Engine busy with \(self.engine.owner?.rawValue ?? "another session", privacy: .public), not starting")
            AudioFeedbackService.shared.playIfEnabled(.error, settings: settings)
            return
        }

        // Checked again after the awaits above: another start may have claimed the
        // slot while this one waited.
        guard startTask == nil else { return }
        let task = Task { await self.begin() }
        startTask = task
        await task.value
        startTask = nil
    }

    private func begin() async {

        #if os(macOS)
        // Captured before we touch anything, so a menu bar click that steals focus
        // does not redirect the text to Inscribe itself. When Inscribe is already in
        // front, the text belongs to the app the user was in before it.
        let frontmost = NSWorkspace.shared.frontmostApplication
        targetApp = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            ? lastExternalApp
            : frontmost
        activeProfile = settings.profile(forBundleIdentifier: targetApp?.bundleIdentifier)

        if let activeProfile {
            Log.dictation.notice("Using profile for \(activeProfile.appName, privacy: .public)")
        }
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
        let usesAI = settings.aiEnabled && !skipAIOnce
        if usesAI {
            aiProcessor.prewarm(promptId: effectivePromptId)
        }

        // Sounded only once capture is live, so the user does not talk over the gap.
        // Nothing slow may come before it: the user waits for this sound to speak.
        AudioFeedbackService.shared.playIfEnabled(.recordingStarted, settings: settings)
        startMaxDurationWatchdog()

        #if os(macOS)
        if settings.showDictationOverlay {
            overlay.show()
            startOverlayTicker()
        }
        #endif
        Log.dictation.notice("Recording started")

        // Accessibility work on the target app, after the sound and the panel and
        // outside the start the release waits for. Each call waits on the target app,
        // and reading the field of an Electron app held the start sound back by up to
        // 0.37 s.
        surroundingText = nil
        #if os(macOS)
        let target = targetApp
        let wantsContext = usesAI && settings.useSurroundingContext
        Task { [weak self] in
            // Chromium-based apps need to be told to build an accessibility tree, and
            // it takes them a moment. Asking now means it is ready by the time we
            // deliver.
            TextInsertionService.prepareForInsertion(into: target)
            guard let self, wantsContext, self.isRecording else { return }
            self.surroundingText = TextInsertionService.focusedFieldContext(in: target)
        }
        #endif
        if usesAI {
            startPrefixWarmer()
        }
    }

    /// Stop, transcribe, optionally run the AI pass, then deliver the text.
    func stopAndProcess() async {
        // A release that lands while the engine is still coming up waits for it,
        // rather than being dropped and leaving the microphone running.
        if let startTask { await startTask.value }

        // Claimed in the same step as the check. Two releases waiting on one start
        // both used to pass `isRecording`, and the second stopped a session the first
        // was already delivering, then cleared the flag while the first still was.
        guard isRecording, !isDelivering else { return }
        isDelivering = true
        defer { isDelivering = false }

        maxDurationTask?.cancel()
        maxDurationTask = nil
        prefixWarmer?.cancel()
        prefixWarmer = nil

        AudioFeedbackService.shared.playIfEnabled(.recordingStopped, settings: settings)

        #if os(macOS)
        stopOverlayTicker()
        if settings.showDictationOverlay, settings.aiEnabled, !skipAIOnce {
            overlay.showProcessing()
        } else {
            overlay.hide()
        }
        #endif

        // Spoken punctuation and word replacements run before the AI pass, so a
        // corrected term reaches the model already spelled the way the user wants
        // rather than being "corrected" back.
        //
        // Done inside the stop task, and an empty result gives up the delivering flag
        // there too. A press waiting on this task then finds the way clear, instead of
        // being refused as "still delivering" by a dictation with nothing to deliver.
        let replacements = settings.wordReplacements
        let stop = Task { [engine] () throws -> String in
            do {
                let raw = try await engine.stopRecording(owner: .dictation)
                let processed = TextProcessor.process(raw, replacements: replacements)
                if processed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.isDelivering = false
                }
                return processed
            } catch {
                self.isDelivering = false
                throw error
            }
        }
        stopTask = stop

        let transcript: String
        do {
            transcript = try await stop.value
            stopTask = nil
        } catch {
            stopTask = nil
            aiProcessor.discardPrewarm()
            #if os(macOS)
            overlay.hide()
            #endif
            AudioFeedbackService.shared.playIfEnabled(.error, settings: settings)
            NotificationService.shared.showErrorIfEnabled(error.localizedDescription, settings: settings)
            Log.dictation.error("Error stopping: \(error, privacy: .public)")
            return
        }

        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            #if os(macOS)
            overlay.hide()
            #endif
            skipAIOnce = false
            // A session loaded for this dictation's prompt would otherwise be picked up
            // by the next one, with the instructions it held when it was loaded.
            aiProcessor.discardPrewarm()

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

        // Kept before anything else can fail or the app can quit: from here on the
        // words survive a hung AI pass, a paste into the wrong window, or a quit
        // mid-delivery. The entry is brought up to date once the text has landed.
        let entry = recordHistory(transcript)

        // A recognizer that failed part-way, or a microphone that changed, still hands
        // back what it had. Delivered, and said: passing it off as complete hides that
        // the end is missing.
        if let engineError = engine.error {
            NotificationService.shared.showErrorIfEnabled(
                "\(engineError.localizedDescription) Everything heard before that was delivered.",
                settings: settings
            )
            Log.dictation.error("Delivering a transcript cut short: \(engineError, privacy: .public)")
        }

        let shouldUseAI = settings.aiEnabled && !skipAIOnce
        skipAIOnce = false

        guard shouldUseAI else {
            // Loaded at the start if AI was on then; "Skip AI" pressed mid-recording
            // leaves it unused.
            aiProcessor.discardPrewarm()
            await deliver(transcript)
            finishHistory(entry, text: transcript, rawText: nil, promptName: nil)
            AudioFeedbackService.shared.playIfEnabled(.processingComplete, settings: settings)
            NotificationService.shared.showTranscriptionCompleteIfEnabled(
                characterCount: transcript.count,
                destination: lastDestination,
                settings: settings
            )
            return
        }

        // Normally read when the dictation began. Asked again now only if that found
        // nothing — a Chromium app can take a moment to expose its fields — and asked
        // of the app the dictation was aimed at, not whatever the user looks at now.
        var surroundingText = self.surroundingText
        #if os(macOS)
        if surroundingText == nil, settings.useSurroundingContext {
            surroundingText = TextInsertionService.focusedFieldContext(in: targetApp)
        }
        #endif
        // The rewrite is shown in the panel as it is written.
        var onPartial: (@MainActor (String) -> Void)?
        #if os(macOS)
        if settings.showDictationOverlay {
            let overlay = self.overlay
            onPartial = { @MainActor text in overlay.showRewrite(text) }
        }
        #endif

        AudioFeedbackService.shared.startProcessingLoopIfEnabled(settings: settings)

        let promptId = effectivePromptId
        let finalText: String
        do {
            let context = surroundingText
            finalText = try await withDeadline(seconds: Self.aiDeadline) { [aiProcessor, onPartial] in
                try await aiProcessor.process(
                    text: transcript,
                    promptId: promptId,
                    surroundingText: context,
                    onPartial: onPartial
                )
            }
            AudioFeedbackService.shared.stopProcessingLoop()
        } catch {
            // A failed AI pass must not cost the user their words, and neither may a
            // model that never answers: past the deadline the raw transcript goes out.
            AudioFeedbackService.shared.stopProcessingLoop()
            let detail = error is DeadlineExceeded
                ? "The AI pass took longer than \(Int(Self.aiDeadline)) seconds."
                : error.localizedDescription
            Log.dictation.error("AI failed, delivering raw transcript: \(detail, privacy: .public)")

            await deliver(transcript)
            finishHistory(entry, text: transcript, rawText: nil, promptName: nil)
            AudioFeedbackService.shared.playIfEnabled(.processingComplete, settings: settings)
            NotificationService.shared.showAIProcessingFailedIfEnabled(
                characterCount: transcript.count,
                errorDetail: detail,
                settings: settings
            )
            return
        }

        await deliver(finalText)
        let promptName = aiProcessor.promptConfiguration
            .prompt(withId: promptId ?? PromptConfiguration.defaultPromptId)?.name
        finishHistory(entry, text: finalText, rawText: transcript, promptName: promptName)
        AudioFeedbackService.shared.playIfEnabled(.processingComplete, settings: settings)
        NotificationService.shared.showTranscriptionCompleteIfEnabled(
            characterCount: finalText.count,
            destination: lastDestination,
            settings: settings
        )
    }

    /// Keep the dictation the moment its words exist.
    private func recordHistory(_ transcript: String) -> Dictation? {
        guard let modelContext else { return nil }
        return DictationHistory.record(
            text: transcript,
            rawText: nil,
            destination: nil,
            promptName: nil,
            settings: settings,
            in: modelContext
        )
    }

    /// Bring the kept entry up to date with what was actually delivered.
    ///
    /// The prompt is named only when its output is what landed. A raw transcript
    /// delivered after the AI pass failed used to carry the prompt's name, and the
    /// default prompt's output carried none.
    private func finishHistory(_ entry: Dictation?, text: String, rawText: String?, promptName: String?) {
        guard let entry, let modelContext, !entry.isDeleted else { return }
        entry.text = text
        entry.rawText = rawText == text ? nil : rawText
        entry.destination = lastDestination
        entry.promptName = promptName
        modelContext.saveOrLog()
    }

    /// Throw away an in-flight recording without producing any text.
    ///
    /// - Parameter quietly: Skip the stop sound, for a recording the user never meant
    ///   to start, such as one begun by Globe pressed as part of Fn+Delete.
    func cancel(quietly: Bool = false) async {
        if let startTask { await startTask.value }
        // Not while a stop is delivering: its words are already on their way.
        guard isRecording, !isDelivering else { return }
        maxDurationTask?.cancel()
        maxDurationTask = nil

        #if os(macOS)
        stopOverlayTicker()
        overlay.hide()
        #endif

        prefixWarmer?.cancel()
        prefixWarmer = nil
        engine.cancelRecording(owner: .dictation)
        aiProcessor.discardPrewarm()
        skipAIOnce = false
        lastDestination = nil
        if !quietly {
            AudioFeedbackService.shared.playIfEnabled(.recordingStopped, settings: settings)
        }
        Log.dictation.notice("Recording cancelled\(quietly ? " — Globe was used as a modifier" : "", privacy: .public)")
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

    /// Keep the warmed AI session reading along as the recognizer confirms words.
    ///
    /// Once a second, and only when a real stretch has been added, since each warming
    /// reads the whole prefix again. Word replacements are applied exactly as they
    /// will be at release, so the prefix matches the request character for character.
    private func startPrefixWarmer() {
        prefixWarmer?.cancel()
        let promptId = effectivePromptId
        prefixWarmer = Task { [weak self] in
            var warmedLength = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.isRecording, !Task.isCancelled else { return }
                let confirmed = self.engine.currentTranscript
                guard confirmed.count >= warmedLength + 40 else { continue }
                warmedLength = confirmed.count
                self.aiProcessor.warmPrefix(
                    promptId: promptId,
                    transcriptSoFar: TextProcessor.process(confirmed, replacements: self.settings.wordReplacements),
                    surroundingText: self.surroundingText
                )
            }
        }
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
