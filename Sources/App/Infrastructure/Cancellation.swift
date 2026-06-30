import Foundation

@inline(__always)
func rethrowCancellationIfNeeded(_ error: any Error) throws {
    if error is CancellationError || Task.isCancelled {
        throw CancellationError()
    }
}
