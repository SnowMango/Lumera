import Foundation
import ImagingCore
import ImageRendering

/// Ordered model decisions backed by one callback-driven core. The async overloads
/// are conveniences; callback callers do not create a Swift Task for each frame.
public actor FrameProcessingSession {
    private nonisolated let core: FrameProcessingCore
    public init(renderer: LumeraRenderer, model: PreparedStyleModel,
                backpressure: SessionBackpressure = .wait, seed: UInt32 = 42,
                resources: ModelProcessingResources? = nil) throws {
        core = try FrameProcessingCore(model: model, backpressure: backpressure, seed: seed, driver: .live(renderer, resources: resources))
    }
    init(model: PreparedStyleModel, backpressure: SessionBackpressure = .wait,
         seed: UInt32 = 42, driver: SessionRenderDriver) throws {
        core = try FrameProcessingCore(model: model, backpressure: backpressure, seed: seed, driver: driver)
    }
    /// Completion is delivered asynchronously. The returned handle cancels unsubmitted
    /// work or suppresses publication after a GPU submission, without releasing GPU resources early.
    @discardableResult
    public nonisolated func enqueue(_ input: PreparedInput, stamp: FrameStamp, edits: EditRequest = .init(),
        targetConditions: CaptureConditions = .init(), event: AdaptationEvent? = nil,
        completion: @escaping (Result<FrameOutcome, Error>) -> Void) throws -> SessionFrameTask {
        let token = SessionCancellation()
        try core.queue.sync { try core.enqueue(input, stamp: stamp, edits: edits, target: targetConditions,
            event: event, token: token, completion: completion) }
        return task(token)
    }
    @discardableResult
    public nonisolated func enqueue(_ source: FrameSource, stamp: FrameStamp, edits: EditRequest = .init(),
        targetConditions: CaptureConditions = .init(), event: AdaptationEvent? = nil,
        completion: @escaping (Result<FrameOutcome, Error>) -> Void) throws -> SessionFrameTask {
        let token = SessionCancellation()
        try core.queue.sync { try core.enqueue(source, stamp: stamp, edits: edits, target: targetConditions,
            event: event, token: token, completion: completion) }
        return task(token)
    }
    private nonisolated func task(_ token: SessionCancellation) -> SessionFrameTask {
        SessionFrameTask { [core] in
            token.cancel()
            core.queue.async { core.cancelUnsubmitted(token) }
        }
    }
    public func enqueue(_ input: PreparedInput, stamp: FrameStamp, edits: EditRequest = .init(),
        targetConditions: CaptureConditions = .init(), event: AdaptationEvent? = nil) async throws -> FrameOutcome {
        try await awaitResult { completion in
            try enqueue(input, stamp: stamp, edits: edits, targetConditions: targetConditions, event: event, completion: completion)
        }
    }
    public func enqueue(_ source: FrameSource, stamp: FrameStamp, edits: EditRequest = .init(),
        targetConditions: CaptureConditions = .init(), event: AdaptationEvent? = nil) async throws -> FrameOutcome {
        try await awaitResult { completion in
            try enqueue(source, stamp: stamp, edits: edits, targetConditions: targetConditions, event: event, completion: completion)
        }
    }
    private func awaitResult(_ submit: (@escaping (Result<FrameOutcome, Error>) -> Void) throws -> SessionFrameTask) async throws -> FrameOutcome {
        try Task.checkCancellation()
        let relay = SessionTaskRelay()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                do { relay.install(try submit { continuation.resume(with: $0) }) }
                catch { continuation.resume(throwing: error) }
            }
        }, onCancel: { relay.cancel() })
    }
    func queueSnapshot() -> (active: Int, pending: Int, waiting: Int) { core.queue.sync { core.queueSnapshot() } }
    public var discardedRecordCount: UInt64 { core.queue.sync { core.discardedRecordCount } }
    public func takeRecords() -> [DecisionRecord] { core.queue.sync { core.takeRecords() } }
    public func reset(_ event: AdaptationEvent) throws { try core.queue.sync { try core.reset(event) } }
}
