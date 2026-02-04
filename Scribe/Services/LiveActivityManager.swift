import Foundation
import ActivityKit
import SwiftUI

#if os(iOS)

// MARK: - Activity Attributes

/// Attributes for the transcription Live Activity
struct TranscriptionActivityAttributes: ActivityAttributes {
    /// Dynamic content that changes during the activity
    struct ContentState: Codable, Hashable {
        var isRecording: Bool
        var isProcessing: Bool
        var characterCount: Int
        var elapsedSeconds: Int
    }

    /// Static content set when starting the activity
    var startTime: Date
}

// MARK: - Live Activity Manager

/// Manages the iOS Live Activity for transcription status
@MainActor
final class LiveActivityManager: ObservableObject {

    // MARK: - Published State

    @Published private(set) var isActivityActive = false

    // MARK: - Private State

    private var currentActivity: Activity<TranscriptionActivityAttributes>?
    private var updateTimer: Timer?
    private var startTime: Date?

    // MARK: - Singleton

    static let shared = LiveActivityManager()

    private init() {}

    // MARK: - Public API

    /// Start a Live Activity for recording
    func startRecordingActivity() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            print("[LiveActivityManager] Live Activities not enabled")
            return
        }

        // End any existing activity
        endActivity()

        startTime = Date()

        let attributes = TranscriptionActivityAttributes(startTime: startTime!)
        let initialState = TranscriptionActivityAttributes.ContentState(
            isRecording: true,
            isProcessing: false,
            characterCount: 0,
            elapsedSeconds: 0
        )

        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: .init(state: initialState, staleDate: nil),
                pushType: nil
            )

            currentActivity = activity
            isActivityActive = true

            // Start update timer
            startUpdateTimer()

            print("[LiveActivityManager] Live Activity started: \(activity.id)")
        } catch {
            print("[LiveActivityManager] Failed to start Live Activity: \(error)")
        }
    }

    /// Update the Live Activity with current transcription progress
    func updateActivity(characterCount: Int, isProcessing: Bool = false) {
        guard let activity = currentActivity else { return }

        let elapsed = Int(Date().timeIntervalSince(startTime ?? Date()))
        let state = TranscriptionActivityAttributes.ContentState(
            isRecording: !isProcessing,
            isProcessing: isProcessing,
            characterCount: characterCount,
            elapsedSeconds: elapsed
        )

        Task {
            await activity.update(.init(state: state, staleDate: nil))
        }
    }

    /// Transition to processing state
    func transitionToProcessing() {
        stopUpdateTimer()
        updateActivity(characterCount: 0, isProcessing: true)
    }

    /// End the Live Activity
    func endActivity() {
        stopUpdateTimer()

        guard let activity = currentActivity else { return }

        let finalState = TranscriptionActivityAttributes.ContentState(
            isRecording: false,
            isProcessing: false,
            characterCount: 0,
            elapsedSeconds: 0
        )

        Task {
            await activity.end(
                .init(state: finalState, staleDate: nil),
                dismissalPolicy: .immediate
            )
        }

        currentActivity = nil
        isActivityActive = false
        startTime = nil

        print("[LiveActivityManager] Live Activity ended")
    }

    // MARK: - Timer

    private func startUpdateTimer() {
        updateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.timerTick()
            }
        }
    }

    private func stopUpdateTimer() {
        updateTimer?.invalidate()
        updateTimer = nil
    }

    private func timerTick() {
        guard let activity = currentActivity else { return }

        let elapsed = Int(Date().timeIntervalSince(startTime ?? Date()))
        let state = TranscriptionActivityAttributes.ContentState(
            isRecording: true,
            isProcessing: false,
            characterCount: 0,  // Will be updated by TranscriptionEngine
            elapsedSeconds: elapsed
        )

        Task {
            await activity.update(.init(state: state, staleDate: nil))
        }
    }
}

// MARK: - Live Activity Widget Views

/// Main Live Activity view for the Lock Screen
struct TranscriptionLiveActivityView: View {
    let context: ActivityViewContext<TranscriptionActivityAttributes>

    var body: some View {
        HStack(spacing: 16) {
            // Icon
            ZStack {
                Circle()
                    .fill(context.state.isRecording ? Color.red : Color.orange)
                    .frame(width: 44, height: 44)

                Image(systemName: context.state.isProcessing ? "brain" : "mic.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
            }

            // Content
            VStack(alignment: .leading, spacing: 4) {
                Text(context.state.isProcessing ? "Processing..." : "Recording")
                    .font(.headline)
                    .foregroundStyle(.primary)

                if context.state.isRecording {
                    Text(formatDuration(context.state.elapsedSeconds))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            Spacer()

            // Character count
            if context.state.characterCount > 0 {
                VStack(alignment: .trailing) {
                    Text("\(context.state.characterCount)")
                        .font(.title2)
                        .fontWeight(.bold)
                        .monospacedDigit()

                    Text("chars")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
    }

    private func formatDuration(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let secs = seconds % 60
        return String(format: "%d:%02d", minutes, secs)
    }
}

// MARK: - Dynamic Island Views

/// Compact leading view for Dynamic Island
struct TranscriptionDynamicIslandCompactLeading: View {
    let context: ActivityViewContext<TranscriptionActivityAttributes>

    var body: some View {
        Image(systemName: context.state.isProcessing ? "brain" : "mic.fill")
            .foregroundStyle(context.state.isRecording ? .red : .orange)
    }
}

/// Compact trailing view for Dynamic Island
struct TranscriptionDynamicIslandCompactTrailing: View {
    let context: ActivityViewContext<TranscriptionActivityAttributes>

    var body: some View {
        Text(formatDuration(context.state.elapsedSeconds))
            .font(.caption)
            .monospacedDigit()
    }

    private func formatDuration(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let secs = seconds % 60
        return String(format: "%d:%02d", minutes, secs)
    }
}

/// Minimal view for Dynamic Island
struct TranscriptionDynamicIslandMinimal: View {
    let context: ActivityViewContext<TranscriptionActivityAttributes>

    var body: some View {
        Image(systemName: "mic.fill")
            .foregroundStyle(.red)
    }
}

/// Expanded view for Dynamic Island
struct TranscriptionDynamicIslandExpanded: View {
    let context: ActivityViewContext<TranscriptionActivityAttributes>

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: context.state.isProcessing ? "brain" : "mic.fill")
                    .font(.title2)
                    .foregroundStyle(context.state.isRecording ? .red : .orange)

                Text(context.state.isProcessing ? "Processing..." : "Recording")
                    .font(.headline)

                Spacer()

                Text(formatDuration(context.state.elapsedSeconds))
                    .font(.title3)
                    .fontWeight(.bold)
                    .monospacedDigit()
            }

            if context.state.characterCount > 0 {
                HStack {
                    Text("\(context.state.characterCount) characters transcribed")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()
                }
            }
        }
        .padding()
    }

    private func formatDuration(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let secs = seconds % 60
        return String(format: "%d:%02d", minutes, secs)
    }
}

#endif
