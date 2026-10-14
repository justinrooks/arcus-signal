import Darwin
import Foundation
import Testing

/// Serializes suites that share the process-wide PostgreSQL integration-test database.
struct SharedDatabaseTestTrait: SuiteTrait, TestScoping {
    private static let lock = SharedDatabaseTestLock()

    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        try await Self.lock.acquire()
        do {
            try await function()
            await Self.lock.release()
        } catch {
            await Self.lock.release()
            throw error
        }
    }
}

extension SuiteTrait where Self == SharedDatabaseTestTrait {
    static var sharedDatabase: Self { SharedDatabaseTestTrait() }
}

private actor SharedDatabaseTestLock {
    private let lockFilePath = FileManager.default.temporaryDirectory
        .appendingPathComponent("arcus-signal-shared-database-tests.lock")
        .path
    private var isLocked = false
    private var lockFileDescriptor: Int32 = -1
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async throws {
        if isLocked {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        } else {
            isLocked = true
        }

        let descriptor = Darwin.open(lockFilePath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            resumeNextWaiter()
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        while Darwin.lockf(descriptor, F_LOCK, 0) != 0 {
            guard errno == EINTR else {
                let lockError = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                Darwin.close(descriptor)
                resumeNextWaiter()
                throw lockError
            }
        }

        lockFileDescriptor = descriptor
    }

    func release() {
        if lockFileDescriptor >= 0 {
            Darwin.lockf(lockFileDescriptor, F_ULOCK, 0)
            Darwin.close(lockFileDescriptor)
            lockFileDescriptor = -1
        }

        resumeNextWaiter()
    }

    private func resumeNextWaiter() {
        guard waiters.isEmpty else {
            waiters.removeFirst().resume()
            return
        }

        isLocked = false
    }
}
