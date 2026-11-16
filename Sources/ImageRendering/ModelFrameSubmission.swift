import Foundation
import Metal
import ImagingCore

/// 已提交的 GPU 命令执行失败时返回的错误。
public struct ModelGPUFailure: Error, Sendable, LocalizedError {
    public let message: String
    public init(message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// 完成的独立输出和可选的全图观测；无工作帧可直接完成。
public struct ModelFrameResult: Sendable {
    public let frame: RenderedFrame
    /// 当前输入的全图观测，可交给后续帧使用。
    public let observations: FrameObservations?
}

/// 已提交的帧任务。等待者以异步挂起的方式共享同一个完成结果。
public final class ModelFrameSubmission: @unchecked Sendable {
    private let lock = UnfairLock()
    private var result: Result<ModelFrameResult, Error>?
    private var callbacks: [(DispatchQueue, (Result<ModelFrameResult, Error>) -> Void)] = []
    package let usesGPU: Bool
    init(usesGPU: Bool = true) { self.usesGPU = usesGPU }
    func finish(_ result: Result<ModelFrameResult, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result; let pending = callbacks; callbacks = []; lock.unlock()
        // 在锁外恢复等待者，完成结果的发布和等待者登记由同一把锁串行化。
        for (queue, callback) in pending { queue.async { callback(result) } }
    }
    /// Registers a completion without creating a Swift Task. Delivery is always asynchronous,
    /// on the supplied queue, including when the result was already available.
    public func onComplete(on queue: DispatchQueue,
                           completion: @escaping (Result<ModelFrameResult, Error>) -> Void) {
        lock.lock()
        if let result { lock.unlock(); queue.async { completion(result) } }
        else { callbacks.append((queue, completion)); lock.unlock() }
    }
    /// Optional async convenience over the same callback completion core.
    /// Cancellation does not release storage still used by an already submitted GPU command.
    public func value() async throws -> ModelFrameResult {
        try await withCheckedThrowingContinuation { continuation in
            onComplete(on: Self.continuationQueue) { continuation.resume(with: $0) }
        }
    }
    private static let continuationQueue = DispatchQueue(label: "Lumera.model.completion", qos: .userInitiated)

}

extension LumeraRenderer {
    /// 编码并提交独立帧输出。可选统计和效果共用命令缓冲区及帧预算。
    /// 同步回调在 GPU 提交或无 GPU 帧的逻辑接受前恰好执行一次；
    /// 可抛错取消接受并归还帧槽和临时预算。
    public func submit(_ input: PreparedInput, plan: FrameRenderPlan,
                       observations: ObservationRequirements? = nil,
                       beforeCommit: () throws -> Void = {}) throws -> ModelFrameSubmission {
        try plan.claim()
        // Keep abandoned commands alive until abortUnsubmitted has removed unpublished
        // output charges. Metal may run completion cleanup while releasing the command.
        var pendingCommand: MTLCommandBuffer?
        defer { withExtendedLifetime(pendingCommand) {} }
        do {
            try FrameEncoder(renderer: self).validate(input, plan: plan)
            let work = try encoder.workRequirements(for: plan)
            if !work.requiresPixelProcessing, plan.residentInput == nil,
               observations?.features.isEmpty != false, input.takeStorageTransfer() {
                let observation: FrameObservations?
                if let requirements = observations {
                    guard let stamp = plan.stamp else { throw LabError.invalid("Session statistics require an original frame stamp") }
                    observation = try frameFeatures.metadataObservation(input, stamp: stamp, requirements: requirements)
                } else { observation = nil }
                let frame = RenderedFrame(texture: input.texture, input: input, plan: plan)
                let submission = ModelFrameSubmission(usesGPU: false)
                try beforeCommit()
                // The existing lease charges this allocation as input already. It retains
                // only the budget, never the texture/plan, so association cannot form a cycle.
                retainOutputLease(on: input.texture, lease: plan.lease)
                plan.lease.completeGPU()
                submission.finish(.success(.init(frame: frame, observations: observation)))
                return submission
            }
            guard let command = queue.makeCommandBuffer() else { throw LabError.io("Cannot create model frame command") }
            pendingCommand = command
            if !work.requiresPixelProcessing, input.pendingEncoding != nil {
                try input.encodePreparation(command)
                let frame = RenderedFrame(texture: input.texture, input: input, plan: plan)
                let submission = ModelFrameSubmission()
                let observation = try observations.map { requirements in
                    guard let stamp = plan.stamp else { throw LabError.invalid("Missing frame stamp") }
                    return try frameFeatures.encode(input, stamp: stamp, requirements: requirements,
                        commandBuffer: command, budgetLimit: plan.workingSet.limit, workingSet: plan.workingSet)
                }
                try beforeCommit()
                command.addCompletedHandler { done in
                    plan.lease.completeGPU()
                    if done.status == .completed && done.error == nil {
                        do { submission.finish(.success(.init(frame: frame, observations: try observation?.resolve()))) }
                        catch { submission.finish(.failure(error)) }
                    } else { submission.finish(.failure(ModelGPUFailure(message: done.error?.localizedDescription ?? "Input GPU failed"))) }
                }
                command.commit()
                return submission
            }
            let encoded = try FrameEncoder(renderer: self).encode(input, plan: plan, commandBuffer: command, alreadyClaimed: true, alreadyValidated: true)
            let owned = try encoded.copyOwned(commandBuffer: command)
            let observation: ObservationReadback?
            if let requirements = observations {
                guard let stamp = plan.stamp else { throw LabError.invalid("Session statistics require an original frame stamp") }
                observation = try frameFeatures.encode(input, stamp: stamp, requirements: requirements,
                    commandBuffer: command, budgetLimit: plan.workingSet.limit, workingSet: plan.workingSet, inputAlreadyBudgeted: plan.residentInput != nil)
            } else { observation = nil }
            let submission = ModelFrameSubmission()
            try beforeCommit()
            command.addCompletedHandler { completed in
                guard completed.status == .completed, completed.error == nil else {
                    submission.finish(.failure(ModelGPUFailure(message: completed.error?.localizedDescription ?? "Model GPU command failed"))); return
                }
                do { submission.finish(.success(.init(frame: try owned.resolve(), observations: try observation?.resolve()))) }
                catch { submission.finish(.failure(error)) }
            }
            command.commit()
            return submission
        } catch {
            // 此入口可放弃自己创建的未提交命令，借用入口的命令生命周期由调用方管理。
            plan.lease.abortUnsubmitted()
            throw error
        }
    }
}

extension LumeraRenderer {
    /// Explicit target/workspace variant. No pixel allocation or output snapshot copy.
    public func submit(_ input: PreparedInput, plan: FrameRenderPlan, output: MTLTexture,
                       workspace: ProcessingWorkspace, request: PreparedProcessingRequest,
                       observations: ObservationRequirements? = nil,
                       beforeCommit: () throws -> Void = {}) throws -> ModelFrameSubmission {
        try FrameEncoder(renderer: self).validate(input, plan: plan)
        guard request.parameters == plan.controls.parameters, request.request == plan.request,
              request.style === plan.style, request.correction === plan.prefix else {
            throw LabError.invalid("Explicit request differs from resolved model plan")
        }
        guard let command = queue.makeCommandBuffer() else { throw LabError.io("Cannot create explicit model command") }
        try validateProcessing(input: input.texture, output: output, request: request, command: command)
        let borrowed = try [workspace.storage.ledger.borrow(input.texture), workspace.storage.ledger.borrow(output)]
        guard workspace.claim(for: request) else { throw FrameAdmissionIssue.incompatibleResources }
        try plan.claim()
        _ = ProcessingCommandOwner.attach(to: command, retaining: [input, output, workspace] + borrowed)
        do {
            try input.encodePreparation(command)
            try encoder.encodePrepared(input.texture, output: output, prepared: request, arena: workspace.storage.arena, command: command)
            let observation: ObservationReadback?
            if let requirements = observations {
                guard let stamp = plan.stamp else { throw LabError.invalid("Missing frame stamp") }
                observation = try frameFeatures.encode(input, stamp: stamp, requirements: requirements,
                    commandBuffer: command, budgetLimit: plan.workingSet.limit, workingSet: plan.workingSet)
            } else { observation = nil }
            let frame = RenderedFrame(texture: output, input: input, plan: plan)
            let submission = ModelFrameSubmission()
            try beforeCommit()
            command.addCompletedHandler { done in
                plan.lease.completeGPU()
                guard done.status == .completed && done.error == nil else {
                    submission.finish(.failure(ModelGPUFailure(message: done.error?.localizedDescription ?? "Model GPU failed"))); return
                }
                do { submission.finish(.success(.init(frame: frame, observations: try observation?.resolve()))) }
                catch { submission.finish(.failure(error)) }
            }
            command.commit(); return submission
        } catch { plan.lease.abortUnsubmitted(); throw error }
    }
}
