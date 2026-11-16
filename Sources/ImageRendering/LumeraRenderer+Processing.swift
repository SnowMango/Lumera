import Foundation
import Metal
import ImagingCore

extension LumeraRenderer {
    /// Encodes into caller-owned output storage without allocating pixels or submitting.
    /// The workspace is single-use. A failed partial encode requires discarding the command.
    public func encode(input: MTLTexture, output: MTLTexture, workspace: ProcessingWorkspace,
                       request: PreparedProcessingRequest, commandBuffer: MTLCommandBuffer) throws -> FrameEncodingLease {
        try validateProcessing(input: input, output: output, request: request, command: commandBuffer)
        let borrowed = try [workspace.storage.ledger.borrow(input), workspace.storage.ledger.borrow(output)]
        guard workspace.claim(for: request) else { throw FrameAdmissionIssue.incompatibleResources }
        _ = ProcessingCommandOwner.attach(to: commandBuffer, retaining: [workspace, input, output] + borrowed)
        try encoder.encodePrepared(input, output: output, prepared: request, arena: workspace.storage.arena, command: commandBuffer)
        return FrameEncodingLease(command: commandBuffer)
    }

    /// Synchronously accepts work; only accepted work receives exactly one completion.
    /// Completion runs on the renderer's delivery queue after GPU execution, never under a lock.
    @discardableResult
    public func processTexture(_ input: MTLTexture, output: MTLTexture, workspace: ProcessingWorkspace,
                               request: PreparedProcessingRequest,
                               completion: @escaping (Result<MTLTexture, Error>) -> Void) -> FrameSubmission {
        processPrepared(output: output, workspace: workspace, request: request, retaining: [input, output],
                        borrow: { try [workspace.storage.ledger.borrow(input), workspace.storage.ledger.borrow(output)] },
                        completion: completion) { command in
            try self.validateProcessing(input: input, output: output, request: request, command: command)
            try self.encoder.encodePrepared(input, output: output, prepared: request,
                arena: workspace.storage.arena, command: command)
        }
    }

    func processPrepared<T>(output: T, workspace: ProcessingWorkspace, request: PreparedProcessingRequest,
                            retaining: [AnyObject], additionalClaim: @escaping () -> Bool = { true },
                            borrow: () throws -> [AnyObject] = { [] }, completion: @escaping (Result<T, Error>) -> Void,
                            encode: @escaping (MTLCommandBuffer) throws -> Void) -> FrameSubmission {
        let borrowed: [AnyObject]
        do { borrowed = try borrow() }
        catch { return .notAccepted((error as? FrameAdmissionIssue) ?? .incompatibleResources) }
        guard request.renderer === self else { return .notAccepted(.incompatibleResources) }
        let task = FrameTask()
        let deliver: (Result<T, Error>) -> Void = { [self, workspace, borrowed] result in
            processingDeliveryQueue.async {
                completion(task.finish(result))
                workspace.scheduler?.finish(task)
                withExtendedLifetime((workspace, borrowed)) {}
            }
        }
        let run = { [self, workspace] in
        processingQueue.async { [self, workspace] in
            guard !task.isCancelled else { deliver(.failure(CancellationError())); return }
            guard let command = queue.makeCommandBuffer() else {
                deliver(.failure(LabError.io("Cannot create processing command"))); return
            }
            command.label = "Lumera.explicit.frame"
            let owner = ProcessingCommandOwner.attach(to: command, retaining: retaining + borrowed + [workspace])
            do {
                try encode(command)
                guard task.beginSubmission() else { deliver(.failure(CancellationError())); return }
                command.addCompletedHandler { done in
                    let result: Result<T, Error> = done.status == .completed && done.error == nil ? .success(output) :
                        .failure(ModelGPUFailure(message: done.error?.localizedDescription ?? "Processing GPU failed"))
                    deliver(result)
                }
                command.commit()
            } catch {
                deliver(.failure(error))
            }
            withExtendedLifetime(owner) {}
        }
        }
        let claim = { workspace.claim(for: request, additionalClaim: additionalClaim) }
        if let scheduler = workspace.scheduler {
            if let issue = scheduler.accept(task, claim: claim, run: run) { return .notAccepted(issue) }
        } else {
            guard claim() else { return .notAccepted(.incompatibleResources) }
            run()
        }
        return .accepted(task)
    }

    func validateProcessing(input: MTLTexture, output: MTLTexture, request: PreparedProcessingRequest,
                            command: MTLCommandBuffer) throws {
        guard request.renderer === self, input.device.registryID == device.registryID,
              output.device.registryID == device.registryID, command.device.registryID == device.registryID,
              command.status == .notEnqueued, command.retainedReferences,
              input.textureType == .type2D, output.textureType == .type2D,
              input.width == request.input.width, input.height == request.input.height,
              output.width == request.outputWidth, output.height == request.outputHeight,
              output.pixelFormat == request.outputPixelFormat, output.usage.contains(.shaderWrite),
              input !== output, !Self.sharesStorage(input, output) else {
            throw LabError.invalid("Incompatible or aliased explicit frame resources")
        }
    }
    private static func sharesStorage(_ a: MTLTexture, _ b: MTLTexture) -> Bool {
        func root(_ t: MTLTexture) -> MTLTexture { var r = t; while let p = r.parent { r = p }; return r }
        if root(a) === root(b) { return true }
        if let x = a.buffer, let y = b.buffer, x === y { return true }
        if let x = a.iosurface, let y = b.iosurface, x === y { return true }
        return false
    }
}
