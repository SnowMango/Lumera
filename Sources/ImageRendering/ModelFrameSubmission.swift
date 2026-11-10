import Foundation
import Metal
import ImagingCore

/// 已提交的 GPU 命令执行失败时返回的错误。
public struct ModelGPUFailure: Error, Sendable, LocalizedError {
    public let message: String
    public init(message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// 同一命令完成的独立输出和可选的全图观测。
public struct ModelFrameResult: Sendable {
    public let frame: RenderedFrame
    /// 当前输入的全图观测，可交给后续帧使用。
    public let observations: FrameObservations?
}

/// 已提交的帧任务。等待者以异步挂起的方式共享同一个完成结果。
public final class ModelFrameSubmission: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<ModelFrameResult, Error>?
    private var waiters: [CheckedContinuation<ModelFrameResult, Error>] = []
    init() {}
    func finish(_ result: Result<ModelFrameResult, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result; let pending = waiters; waiters = []; lock.unlock()
        // 在锁外恢复等待者，完成结果的发布和等待者登记由同一把锁串行化。
        for waiter in pending { waiter.resume(with: result) }
    }
    /// 等待 GPU 执行并解析结果。等待任务取消时，已提交的 GPU 命令仍会完成。
    public func value() async throws -> ModelFrameResult {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result { lock.unlock(); continuation.resume(with: result) }
            else { waiters.append(continuation); lock.unlock() }
        }
    }
}

extension LumeraRenderer {
    /// 编码并提交独立帧输出。可选统计和效果共用命令缓冲区及帧预算。
    /// 同步回调在提交前执行，可抛错取消提交并归还帧槽和临时预算。
    public func submit(_ input: PreparedInput, plan: FrameRenderPlan,
                       observations: ObservationRequirements? = nil,
                       beforeCommit: () throws -> Void = {}) throws -> ModelFrameSubmission {
        guard let command = queue.makeCommandBuffer() else { throw LabError.io("Cannot create model frame command") }
        try plan.claim()
        do {
            let encoded = try FrameEncoder(renderer: self).encode(input, plan: plan, commandBuffer: command, alreadyClaimed: true)
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
