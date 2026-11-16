import Foundation
import ImagingCore

public enum FrameSubmission {
    case accepted(FrameTask)
    /// No completion is scheduled for a request that was not accepted.
    case notAccepted(FrameAdmissionIssue)
}

/// Cancellation never releases resources that the GPU may still be using.
public final class FrameTask: @unchecked Sendable {
    public enum Status: Sendable { case queued, submitted, completed, cancelled }
    private let lock = UnfairLock()
    private var state: Status = .queued
    private var cancellationRequested = false
    public var status: Status { lock.withLock { state } }
    public func cancel() { lock.withLock { if state != .completed { cancellationRequested = true } } }
    var isCancelled: Bool { lock.withLock { cancellationRequested } }
    func beginSubmission() -> Bool {
        lock.withLock {
            guard !cancellationRequested else { return false }
            state = .submitted; return true
        }
    }
    func finish<T>(_ result: Result<T, Error>) -> Result<T, Error> {
        lock.withLock {
            state = cancellationRequested ? .cancelled : .completed
            return cancellationRequested ? .failure(CancellationError()) : result
        }
    }
}
