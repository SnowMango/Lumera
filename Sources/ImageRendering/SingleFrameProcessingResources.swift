import Foundation
import Metal
import ImagingCore

/// One frame's resources, without a pool, idle cache, stream manager or extra slots.
struct SingleFrameProcessingResources {
    let workspace: ProcessingWorkspace
    let output: ProcessingTextureStorage?
    init(request: PreparedProcessingRequest, output external: MTLTexture? = nil) throws {
        let ledger = ProcessingResourceLedger(limits: .init(maxResidentBytes: Int.max),
            policy: .init(maxResidentBytes: Int.max, maxIdleBytes: 0))
        let output: ProcessingTextureStorage?
        let texture: MTLTexture
        if let external { output = nil; texture = external }
        else {
            let storage = try ProcessingTextureStorage(device: request.device, width: request.outputWidth,
                height: request.outputHeight, format: request.outputPixelFormat, ledger: ledger)
            output = storage; texture = storage.texture
        }
        self.output = output
        workspace = ProcessingWorkspace(try ProcessingWorkspaceStorage(request: request, output: texture, ledger: ledger)) { _ in }
    }
}

/// Used only by optional async conveniences. The callback core has no Task dependency.
final class ProcessingCancellationRelay: @unchecked Sendable {
    private let lock = UnfairLock()
    private var task: FrameTask?
    private var cancelled = false
    func install(_ task: FrameTask) {
        let shouldCancel = lock.withLock { self.task = task; return cancelled }
        if shouldCancel { task.cancel() }
    }
    func cancel() {
        let task = lock.withLock { cancelled = true; return task }
        task?.cancel()
    }
}

extension LumeraRenderer {
    func awaitProcessing<T>(_ submit: (@escaping (Result<T, Error>) -> Void) -> FrameSubmission) async throws -> T {
        try Task.checkCancellation()
        let relay = ProcessingCancellationRelay()
        return try await withTaskCancellationHandler(operation: {
            let result: T = try await withCheckedThrowingContinuation { continuation in
                switch submit({ continuation.resume(with: $0) }) {
                case .accepted(let task): relay.install(task)
                case .notAccepted(let issue): continuation.resume(throwing: issue)
                }
            }
            try Task.checkCancellation()
            return result
        }, onCancel: { relay.cancel() })
    }
}
