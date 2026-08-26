import Foundation
import AVFoundation

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Service for playing audio feedback sounds
@MainActor
final class AudioFeedbackService {

    // MARK: - Sound Types

    enum Sound {
        case recordingStarted
        case recordingStopped
        case processingComplete
        case error

        var systemSoundID: UInt32 {
            #if os(iOS)
            switch self {
            case .recordingStarted:
                return 1113  // begin_record.caf
            case .recordingStopped:
                return 1114  // end_record.caf
            case .processingComplete:
                return 1057  // Tink
            case .error:
                return 1053  // Basso
            }
            #else
            // macOS uses NSSound instead
            return 0
            #endif
        }

        #if os(macOS)
        var macOSSoundName: String {
            switch self {
            case .recordingStarted:
                return "Morse"
            case .recordingStopped:
                return "Pop"
            case .processingComplete:
                return "Glass"
            case .error:
                return "Basso"
            }
        }
        #endif
    }

    // MARK: - Singleton

    static let shared = AudioFeedbackService()

    #if os(macOS)
    private var loopingSound: NSSound?
    #endif

    private init() {}

    // MARK: - Public API

    /// Play a feedback sound using default sound names
    func play(_ sound: Sound) {
        #if os(iOS)
        AudioServicesPlaySystemSound(sound.systemSoundID)
        #elseif os(macOS)
        NSSound(named: sound.macOSSoundName)?.play()
        #endif
    }

    /// Play a feedback sound if enabled, using the user's chosen sound
    func playIfEnabled(_ sound: Sound, settings: AppSettings) {
        guard settings.playFeedbackSounds else { return }
        #if os(iOS)
        AudioServicesPlaySystemSound(sound.systemSoundID)
        #elseif os(macOS)
        let soundId = settings.soundId(for: sound)
        SoundCatalog.shared.makeNSSound(for: soundId)?.play()
        #endif
    }

    // MARK: - Processing Loop (macOS)

    #if os(macOS)
    /// Start a looping sound to indicate AI processing is in progress
    func startProcessingLoop(soundId: String = "Bottle") {
        stopProcessingLoop()
        guard let sound = SoundCatalog.shared.makeNSSound(for: soundId) else { return }
        sound.loops = true
        sound.play()
        loopingSound = sound
    }

    /// Stop the processing loop sound
    func stopProcessingLoop() {
        loopingSound?.stop()
        loopingSound = nil
    }

    /// Start processing loop if the processing indicator is enabled
    func startProcessingLoopIfEnabled(settings: AppSettings) {
        guard settings.playProcessingIndicator else { return }
        startProcessingLoop(soundId: settings.processingSoundName)
    }
    #endif

    // MARK: - Haptic Feedback (iOS only)

    #if os(iOS)
    /// Play haptic feedback for recording start
    func playStartHaptic() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
    }

    /// Play haptic feedback for recording stop
    func playStopHaptic() {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
    }

    /// Play haptic feedback for error
    func playErrorHaptic() {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.error)
    }
    #endif
}

// MARK: - Notification Service

/// Service for showing system notifications
@MainActor
final class NotificationService {

    // MARK: - Singleton

    static let shared = NotificationService()

    private init() {
        requestAuthorization()
    }

    // MARK: - Authorization

    private func requestAuthorization() {
        Task {
            do {
                let center = UNUserNotificationCenter.current()
                try await center.requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                print("[NotificationService] Authorization failed: \(error)")
            }
        }
    }

    // MARK: - Delivery

    /// Post a banner.
    ///
    /// - Parameter withSound: The app plays its own completion and error sounds, so a
    ///   notification chime on top of them is one noise too many. Only sounds when the
    ///   app's own feedback is switched off.
    private func post(title: String, body: String, withSound: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if withSound {
            content.sound = .default
        }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Public API

    /// Announce a finished transcript, if the user wants to hear about it.
    ///
    /// - Parameter destination: Where the text went — an app name, or "Clipboard".
    ///   Saying "copied to clipboard" when it was typed into Slack is worse than silence.
    func showTranscriptionCompleteIfEnabled(
        characterCount: Int,
        destination: String?,
        settings: AppSettings
    ) {
        guard settings.showNotifications else { return }

        let body: String
        switch destination {
        case .some(let place) where place != "Clipboard":
            body = "\(characterCount) characters typed into \(place)"
        case .some:
            body = "\(characterCount) characters copied to the clipboard"
        case .none:
            body = "\(characterCount) characters ready"
        }

        post(title: "Transcription Complete", body: body, withSound: !settings.playFeedbackSounds)
    }

    /// Report a failure, if error notifications are on.
    func showErrorIfEnabled(_ message: String, settings: AppSettings) {
        guard settings.notifyOnError else { return }
        post(title: "Transcription Error", body: message, withSound: !settings.playFeedbackSounds)
    }

    /// Report that the AI pass failed but the raw transcript survived.
    func showAIProcessingFailedIfEnabled(
        characterCount: Int,
        errorDetail: String,
        settings: AppSettings
    ) {
        guard settings.notifyOnError else { return }
        post(
            title: "AI Processing Skipped",
            body: "\(characterCount) characters delivered without AI processing. \(errorDetail)",
            withSound: !settings.playFeedbackSounds
        )
    }
}

// Required import for notifications
import UserNotifications
