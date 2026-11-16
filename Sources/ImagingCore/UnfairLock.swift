import os

/// A nonrecursive mutex for synchronous shared state. Copies share the same lock.
/// Prefer `withLock`; manual locking must unlock on the acquiring thread, without
/// crossing an `await`. Callbacks and continuation resumption belong outside the lock.
/// The allocated backing keeps the unfair lock's address stable when this value moves.
public struct UnfairLock: Sendable {
    @usableFromInline
    let storage: OSAllocatedUnfairLock<Void>

    @inlinable
    public init() { storage = OSAllocatedUnfairLock() }

    @inlinable
    @available(*, noasync, message: "Use withLock for a synchronous critical section")
    public func lock() { storage.lock() }

    @inlinable
    @available(*, noasync, message: "Use withLock for a synchronous critical section")
    public func unlock() { storage.unlock() }

    /// Runs a synchronous operation exclusively, releasing the lock even if it throws.
    /// The caller is responsible for protecting every access to its shared state.
    @inlinable
    public func withLock<Result>(_ operation: () throws -> Result) rethrows -> Result {
        try storage.withLockUnchecked { _ in try operation() }
    }
}
