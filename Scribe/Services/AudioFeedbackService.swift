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

    private init() {}

    // MARK: - Public API

    /// Play a feedback sound
    func play(_ sound: Sound) {
        #if os(iOS)
        AudioServicesPlaySystemSound(sound.systemSoundID)
        #elseif os(macOS)
        NSSound(named: sound.macOSSoundName)?.play()
        #endif
    }

    /// Play a feedback sound if enabled in settings
    func playIfEnabled(_ sound: Sound, settings: AppSettings) {
        guard settings.playFeedbackSounds else { return }
        play(sound)
    }

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

    // MARK: - Public API

    /// Show a notification when transcription is complete
    func showTranscriptionComplete(characterCount: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Transcription Complete"
        content.body = "\(characterCount) characters copied to clipboard"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    /// Show a notification for errors
    func showError(_ message: String) {
        let content = UNMutableNotificationContent()
        content.title = "Transcription Error"
        content.body = message
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    /// Show notification if enabled in settings
    func showTranscriptionCompleteIfEnabled(characterCount: Int, settings: AppSettings) {
        guard settings.showNotifications else { return }
        showTranscriptionComplete(characterCount: characterCount)
    }
}

// Required import for notifications
import UserNotifications
