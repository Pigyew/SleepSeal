import Foundation

/// A short-lived cancellation epoch bridges the main UI/event callbacks and
/// the serialized guard. Cancellation is visible even while that guard waits
/// for a queued normal-quit request on the main thread.
final class BlockingAppsCancellation {
    private let lock = NSLock()
    private var epoch: UInt64 = 0

    func token() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return epoch
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        epoch &+= 1
    }

    func isCancelled(_ token: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return token != epoch
    }
}
