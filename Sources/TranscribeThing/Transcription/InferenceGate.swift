import Foundation

/// Serializes every local model load, unload, delete and inference, in FIFO order. Concurrent Core ML work
/// can crash inside libBNNS (FluidAudio issue #661), and AsrManager is unsafe to call re-entrantly (it
/// suspends mid-inference).
actor InferenceGate {
    static let shared = InferenceGate()

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var isBusy = false
    private var waiters: [Waiter] = []

    /// Number of callers currently waiting for their turn (not counting the one running).
    var queueLength: Int { waiters.count }

    /// Runs `operation` once every earlier caller has finished. A caller cancelled while waiting
    /// leaves the queue and throws `CancellationError` without running.
    func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if !isBusy {
            isBusy = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release() {
        if waiters.isEmpty {
            isBusy = false
        } else {
            // Hand the turn straight to the next waiter; the gate stays busy.
            waiters.removeFirst().continuation.resume()
        }
    }
}
