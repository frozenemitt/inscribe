import Foundation
import Observation

/// Whether meetings are actually being written to disk.
///
/// The container falls back to an in-memory store when the file cannot be opened —
/// a migration it cannot perform, a corrupt file, a permissions problem. Dictation is
/// unaffected, but every meeting recorded in that state disappears on quit. Silent
/// degradation here costs the user a meeting they believed was saved, so the state is
/// held here and shown in the meetings window.
@MainActor
@Observable
final class MeetingStoreStatus {
    static let shared = MeetingStoreStatus()

    private(set) var isPersistent = true
    private(set) var failureReason: String?

    private init() {}

    nonisolated func setPersistent(_ value: Bool, reason: String? = nil) {
        MainActor.assumeIsolated {
            isPersistent = value
            failureReason = reason
        }
    }
}
