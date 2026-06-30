import Foundation

final class PressureArtifactCatalogTestGate: @unchecked Sendable {
    static let shared = PressureArtifactCatalogTestGate()

    private let lock = NSLock()
    private var isLocked = false
    private var nextWaiterID = 0
    private var waiters: [Int: CheckedContinuation<Void, any Error>] = [:]
    private var queue: [Int] = []
    private var cancelledWaiterIDs = Set<Int>()

    func withExclusiveAccess<T>(_ operation: () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        try await acquire()
        defer { release() }

        return try await operation()
    }

    private func acquire() async throws {
        let waiterID = lock.withLock { () -> Int? in
            if !isLocked {
                isLocked = true
                return nil
            }

            let waiterID = nextWaiterID
            nextWaiterID += 1
            return waiterID
        }

        guard let waiterID else {
            return
        }

        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let shouldCancel = self.lock.withLock {
                    if self.cancelledWaiterIDs.remove(waiterID) != nil {
                        return true
                    }

                    self.waiters[waiterID] = continuation
                    self.queue.append(waiterID)
                    return false
                }

                if shouldCancel {
                    continuation.resume(throwing: CancellationError())
                }
            }
        }, onCancel: {
            self.cancelWaiter(id: waiterID)
        })
    }

    private func cancelWaiter(id: Int) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
            guard let continuation = waiters.removeValue(forKey: id) else {
                cancelledWaiterIDs.insert(id)
                return nil
            }

            if let index = queue.firstIndex(of: id) {
                queue.remove(at: index)
            }

            return continuation
        }

        guard let continuation else {
            return
        }

        continuation.resume(throwing: CancellationError())
    }

    private func release() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
            while let nextID = queue.first {
                queue.removeFirst()

                guard let continuation = waiters.removeValue(forKey: nextID) else {
                    continue
                }

                return continuation
            }

            isLocked = false
            return nil
        }

        continuation?.resume()
    }
}
