import Foundation
import ImagingCore

public final class SessionFrameTask: @unchecked Sendable {
    private let cancellation: () -> Void
    init(_ cancellation: @escaping () -> Void) { self.cancellation = cancellation }
    public func cancel() { cancellation() }
}
final class SessionTaskRelay: @unchecked Sendable {
    private let lock = UnfairLock()
    private var task: SessionFrameTask?
    private var cancelled = false
    func install(_ value: SessionFrameTask) {
        let cancel = lock.withLock { task = value; return cancelled }
        if cancel { value.cancel() }
    }
    func cancel() { let value = lock.withLock { cancelled = true; return task }; value?.cancel() }
}
final class SessionCompletion {
    private let queue: DispatchQueue
    private let callback: (Result<FrameOutcome, Error>) -> Void
    private var finished = false // accessed only on the session core queue
    init(queue: DispatchQueue, callback: @escaping (Result<FrameOutcome, Error>) -> Void) {
        self.queue = queue; self.callback = callback
    }
    func resume(with result: Result<FrameOutcome, Error>) {
        guard !finished else { return }; finished = true
        queue.async { [callback] in callback(result) }
    }
    func resume(returning value: FrameOutcome) { resume(with: .success(value)) }
    func resume(throwing error: Error) { resume(with: .failure(error)) }
}
