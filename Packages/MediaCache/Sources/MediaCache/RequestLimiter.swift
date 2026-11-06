import Foundation

public enum RequestPriority: Sendable {
    /// On screen now.
    case visible
    /// Expected to scroll into view soon.
    case prefetch
}

/// Limits concurrent work (e.g. at most 4 thumbnail downloads, to spare the Pi).
/// Waiters are served visible-first, then FIFO. A cancelled waiter leaves the
/// queue without taking a slot.
public actor RequestLimiter {
    private let limit: Int
    private var running = 0
    private var queues: [RequestPriority: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)]] = [
        .visible: [], .prefetch: [],
    ]

    public init(limit: Int) {
        precondition(limit > 0)
        self.limit = limit
    }

    public var activeCount: Int { running }

    public func run<T: Sendable>(priority: RequestPriority, _ operation: @Sendable () async throws -> T) async throws -> T {
        try await acquire(priority: priority)
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire(priority: RequestPriority) async throws {
        if running < limit {
            running += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queues[priority, default: []].append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func release() {
        if let next = dequeue() {
            // The slot passes straight to the next waiter.
            next.resume()
        } else {
            running -= 1
        }
    }

    private func dequeue() -> CheckedContinuation<Void, any Error>? {
        for priority in [RequestPriority.visible, .prefetch] where !(queues[priority]?.isEmpty ?? true) {
            return queues[priority]!.removeFirst().continuation
        }
        return nil
    }

    private func cancelWaiter(_ id: UUID) {
        for priority in [RequestPriority.visible, .prefetch] {
            if let index = queues[priority]?.firstIndex(where: { $0.id == id }) {
                let waiter = queues[priority]!.remove(at: index)
                waiter.continuation.resume(throwing: CancellationError())
                return
            }
        }
    }
}
