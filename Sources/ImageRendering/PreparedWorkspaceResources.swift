import Metal
import ImagingCore

/// One caller-owned reusable workspace, without an internally allocated output pool.
/// External textures/buffers retain their own ownership and reuse policy.
public final class PreparedWorkspaceResources: @unchecked Sendable {
    private let lock = UnfairLock()
    private var storage: ProcessingWorkspaceStorage?
    private var leased = false
    init(_ storage: ProcessingWorkspaceStorage) { self.storage = storage }
    /// A fresh single-submission handle; no pixel storage is allocated here.
    public func acquire() throws -> ProcessingWorkspace {
        try lock.withLock {
            guard let storage else { throw FrameAdmissionIssue.closed }
            guard !leased else { throw FrameAdmissionIssue.busy }
            leased = true
            return ProcessingWorkspace(storage) { [weak self] _ in
                self?.lock.withLock { self?.leased = false }
            }
        }
    }
    /// Active commands/handles retain their storage until safe to release.
    public func close() { lock.withLock { storage = nil } }
}

extension ProcessingResources {
    /// Explicit preparation for caller-owned input/output textures (including CVMetalTexture
    /// bindings). No output texture or PixelBuffer pool is created. Retain the returned owner
    /// and acquire a new handle per frame; close it when configuration changes.
    public func prepareWorkspace(input: MTLTexture, output: MTLTexture,
                                 request: PreparedProcessingRequest) throws -> PreparedWorkspaceResources {
        try checkExternalPreparation(request)
        guard let command = request.renderer.queue.makeCommandBuffer() else { throw FrameAdmissionIssue.incompatibleResources }
        try request.renderer.validateProcessing(input: input, output: output, request: request, command: command)
        let borrowed = try [ledger.borrow(input, adaptingPolicy: true), ledger.borrow(output, adaptingPolicy: true)]
        let storage = try ProcessingWorkspaceStorage(request: request, output: output, ledger: ledger, preparationInput: input)
        withExtendedLifetime(borrowed) {}
        return PreparedWorkspaceResources(storage)
    }
}
