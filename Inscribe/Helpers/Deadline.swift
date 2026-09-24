import Foundation
import os

/// The work did not finish before its deadline.
struct DeadlineExceeded: Error {}

/// Run `operation`, and give up waiting for it after `seconds`.
///
/// A task group cannot do this. `withTaskGroup` returns only once every child has
/// finished, and cancelling a child only sets a flag on it, so a group racing a timer
/// against work that ignores cancellation waits exactly as long as the work takes. The
/// stop path's time limits were built that way and could never fire.
///
/// Here the two sides race to resume one continuation, and whichever arrives second is
/// ignored. Work that loses is not waited for: it runs to completion, or forever, on
/// its own, holding whatever it captured.
func withDeadline<T: Sendable>(
    seconds: Double,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        let settled = OSAllocatedUnfairLock(initialState: false)
        let settle: @Sendable (Result<T, any Error>) -> Void = { result in
            let first = settled.withLock { done in
                defer { done = true }
                return !done
            }
            if first { continuation.resume(with: result) }
        }

        let timer = Task {
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { settle(.failure(DeadlineExceeded())) }
        }

        Task {
            do {
                let value = try await operation()
                timer.cancel()
                settle(.success(value))
            } catch {
                timer.cancel()
                settle(.failure(error))
            }
        }
    }
}
