import Foundation
import ImagingCore
import ImageRendering

/// One ordered stream. CPU decisions and GPU submission are serialized; pending
/// admitted frames share the prepared model's bounded slots and memory ledger.
/// Waiting callers own their source buffers until admission. At most one additional
/// queue of maxInFlightFrames callers may wait; unlimited producer fan-out rejects.
public actor CameraSession {
    private struct Request {
        let input: PreparedInput
        let stamp: FrameStamp
        let edits: EditRequest
        let target: CaptureConditions
        let event: AdaptationEvent?
        let cancellation: SessionCancellation
        let continuation: CheckedContinuation<FrameOutcome, Error>
        var reservation: FrameReservation?
        let epoch: UInt64
    }
    private let model: PreparedCameraModel
    private let driver: SessionRenderDriver
    private let backpressure: SessionBackpressure
    private let seed: UInt32
    private let capacity: Int
    private var pending: [Request] = []
    private var waiting: [Request] = []
    private var active: Request?
    private var workerRunning = false
    // 会话本地代次与源 FrameStamp.generation 不同，用于屏蔽 reset 后迟到的完成回调。
    private var epoch: UInt64 = 0
    private var order = SessionOrder()
    private var state: DecisionEngineState?
    private var previousObservations: FrameObservations?
    private var pendingReset: AdaptationEvent?
    private var records: [DecisionRecord] = []
    /// Drain records regularly for complete replay. Ring overflow is explicit.
    public private(set) var discardedRecordCount: UInt64 = 0
    private let recordLimit: Int

    /// 为一个有序视频流创建会话；模型须已准备资源和执行预算。
    /// 延迟观测的帧数/秒数限制不能超过模型声明的有效期；采集、输入准备和编码仍由宿主负责。
    public init(renderer: LumeraRenderer, model: PreparedCameraModel,
                backpressure: SessionBackpressure = .wait, seed: UInt32 = 42) throws {
        try self.init(model: model, backpressure: backpressure, seed: seed, driver: .live(renderer))
    }
    init(model: PreparedCameraModel, backpressure: SessionBackpressure = .wait,
         seed: UInt32 = 42, driver: SessionRenderDriver) throws {
        try model.execution.validate()
        if case .delayed(let frames, let seconds) = model.execution.statisticsLatency,
           !model.compiled.definition.observations.features.isEmpty {
            let validity = model.compiled.definition.observations.validity
            guard frames <= validity.maxAgeFrames, seconds <= validity.maxAgeSeconds else {
                throw LabError.unsupported("Model does not authorize this delayed observation policy")
            }
        }
        self.model = model; self.driver = driver; self.backpressure = backpressure; self.seed = seed
        capacity = model.execution.budget.maxInFlightFrames
        recordLimit = max(64, min(4096, min(capacity, 64) * 64))
    }

    /// 接收已准备好的完整输入，等待渲染完成或明确的丢帧结果。
    /// stamp 必须使用源帧序号与 PTS；被丢弃的已接收帧也消耗序号，不能重新编号重试。
    /// targetConditions 是目标相机条件；源拍摄事实只从 input 获取。
    /// reset 必须走会话边界方法，不能作为普通排队事件；取消已提交帧只抑制结果发布。
    public func enqueue(_ input: PreparedInput, stamp: FrameStamp, edits: EditRequest = .init(),
                        targetConditions: CaptureConditions = .init(), event: AdaptationEvent? = nil) async throws -> FrameOutcome {
        try Task.checkCancellation(); try targetConditions.validate()
        // Reset is a session boundary, not a queued event that could leave old jobs live.
        if case .reset = event { throw LabError.invalid("Use CameraSession.reset for stream reset events") }
        guard pendingReset == nil || event == nil else { throw LabError.invalid("Submit the reset frame before applying lock/unlock events") }
        try order.accept(stamp)
        let token = SessionCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let request = Request(input: input, stamp: stamp, edits: edits, target: targetConditions, event: event,
                    cancellation: token, continuation: continuation, reservation: nil, epoch: epoch)
                accept(request)
            }
        }, onCancel: {
            token.cancel()
            Task { await self.cancelUnsubmitted(token) }
        })
    }

    func queueSnapshot() -> (active: Int, pending: Int, waiting: Int) { (active == nil ? 0 : 1, pending.count, waiting.count) }

    /// 取走并清空现有回放记录；discardedRecordCount 不随读取清零。
    /// 记录在提交后写入，说明决策已提交，并不保证随后 GPU 一定成功。
    public func takeRecords() -> [DecisionRecord] { let copy = records; records = []; return copy }

    /// 清除决策/观测历史和待提交队列，并使旧代次结果失效。
    /// 已提交 GPU 工作仍须完成资源清理；下一接收帧承接 reset 事件。
    public func reset(_ event: AdaptationEvent) throws {
        guard case .reset = event else { throw LabError.invalid("Session reset requires a reset event") }
        invalidate(reason: .reset, event: event)
    }
    private func invalidate(reason: FrameDropReason, event: AdaptationEvent) {
        epoch &+= 1; state = nil; previousObservations = nil; pendingReset = event; order.reset()
        active?.cancellation.cancel()
        let abandoned = pending + waiting; pending = []; waiting = []
        for request in abandoned { request.reservation?.cancel(); request.continuation.resume(returning: .dropped(request.stamp, reason)) }
    }
    // 等待者和待提交者可立即释放；active 任务的存储必须等自己的观察/提交完成。
    private func cancelUnsubmitted(_ token: SessionCancellation) {
        if let index = waiting.firstIndex(where: { $0.cancellation === token }) {
            let cancelled = waiting.remove(at: index)
            cancelled.continuation.resume(returning: .dropped(cancelled.stamp, .cancelled))
        } else if let index = pending.firstIndex(where: { $0.cancellation === token }) {
            let cancelled = pending.remove(at: index)
            cancelled.reservation?.cancel()
            cancelled.continuation.resume(returning: .dropped(cancelled.stamp, .cancelled))
            while pending.count + (active == nil ? 0 : 1) < capacity, !waiting.isEmpty { admit(waiting.removeFirst()) }
            startWorker()
        }
        // An active observation/submission owns its GPU lifetime until completion;
        // the synchronous token still rejects commit and later output publication.
    }
    // 背压只替换尚未提交的帧；队列满且仅剩 active 时丢弃新帧，不撤销旧提交。
    private func accept(_ request: Request) {
        let count = pending.count + (active == nil ? 0 : 1)
        if count >= capacity {
            switch backpressure {
            case .wait:
                guard waiting.count < capacity else {
                    request.continuation.resume(throwing: LabError.invalid("Too many waiting producers; await admission before enqueueing more frames")); return
                }
                waiting.append(request); return
            case .dropUnsubmitted:
                guard !pending.isEmpty else { request.continuation.resume(returning: .dropped(request.stamp, .backpressure)); return }
                let removed = pending.removeFirst(); removed.reservation?.cancel()
                removed.continuation.resume(returning: .dropped(removed.stamp, .backpressure))
            }
        }
        admit(request)
        startWorker()
    }
    // 入队时先占有共享帧额度，防止输入准备完成后无界堆积。
    private func admit(_ request: Request) {
        var request = request
        do {
            try request.cancellation.check()
            let reservation = try model.reserveFrame()
            guard request.input.residentStorageBytes < reservation.execution.budget.maxResidentBytes else {
                reservation.cancel()
                throw LabError.invalid("Prepared input exceeds the admitted frame memory allowance")
            }
            request.reservation = reservation
            pending.append(request)
        } catch is CancellationError { request.continuation.resume(returning: .dropped(request.stamp, .cancelled)) }
        catch { request.continuation.resume(throwing: error) }
    }
    private func startWorker() {
        guard !workerRunning else { return }
        workerRunning = true
        Task { await drain() }
    }
    // actor 在 await 期间可重入；workerRunning 保证始终只有一个顺序消费任务。
    private func drain() async {
        while !pending.isEmpty {
            let request = pending.removeFirst(); active = request
            await execute(request)
            active = nil
            while pending.count < capacity, !waiting.isEmpty { admit(waiting.removeFirst()) }
        }
        workerRunning = false
    }
    private func execute(_ request: Request) async {
        guard let reservation = request.reservation else { request.continuation.resume(throwing: LabError.invalid("Missing frame admission")); return }
        defer { reservation.cancel() }
        var submitted = false
        do {
            try request.cancellation.check()
            guard request.epoch == epoch else { request.continuation.resume(returning: .dropped(request.stamp, .reset)); return }
            let input = request.input, stamp = request.stamp
            let recipe = try input.source.effectiveRecipe.digest()
            let facts = FrameInputFacts(stamp: stamp, inputID: input.inputID, sourceID: input.sourceID,
                calibrationID: input.calibrationID, effectiveRecipeDigest: recipe, captureConditions: input.captureConditions, effectiveRecipe: input.source.effectiveRecipe)
            let requirements = model.compiled.definition.observations
            let observation: FrameObservations
            let delayed: Bool
            if case .delayed = model.execution.statisticsLatency, !requirements.features.isEmpty { delayed = true } else { delayed = false }
            // 延迟模式只能复用同一个完整旧包；无有效包时显式构造缺测，而非混合新旧事实。
            if delayed {
                if let packet = previousObservations, validDelayed(packet, facts: facts, requirements: requirements) { observation = packet }
                else {
                    var missing = FrameObservations(stamp: stamp, sourceID: input.sourceID, calibrationID: input.calibrationID,
                        featureDigest: model.compiled.featureDigest)
                    missing.captureConditions = input.captureConditions
                    missing.features = requirements.features.map { .init(id: $0.id, value: nil, invalidReason: "No valid delayed observation") }
                    observation = missing
                }
            } else {
                observation = try await driver.observe(input, stamp, requirements, reservation.execution.budget.maxResidentBytes)
            }
            try request.cancellation.check()
            guard request.epoch == epoch else { request.continuation.resume(returning: .dropped(stamp, .reset)); return }
            var event = request.event ?? pendingReset
            if let previous = state, previous.inputRecipeDigest != recipe || previous.fallback.controls.sourceID != input.sourceID || previous.fallback.controls.calibrationID != input.calibrationID {
                guard request.event == nil else { throw LabError.invalid("Source changed; reset before applying a lock event") }
                event = .reset(.sourceChanged)
            }
            let record = DecisionRecord(modelDigest: model.compiled.identity, inputRecipeDigest: recipe, resourceDigest: model.resourceDigest,
                context: .init(evaluationStamp: stamp, observations: observation, targetConditions: request.target), event: event,
                edits: request.edits, seed: seed, currentInput: facts)
            // 实时和离线回放复用同一个决策步骤，避免两套自动/编辑顺序逐渐分叉。
            let step = try DecisionReplay.step(record, model: model.compiled, state: state)
            let plan = try RenderPlanner().plan(step.decision.controls, input: input, model: model, stamp: stamp, seed: seed, reservation: reservation)
            defer { plan.cancel() }
            let submission = try driver.submit(input, plan, delayed ? requirements : nil, { try request.cancellation.markSubmitted() })
            // No suspension between successful commit and mathematical history update.
            submitted = true; state = step.state; pendingReset = nil
            if records.count == recordLimit { records.removeFirst(); discardedRecordCount &+= 1 }
            records.append(record)
            let result = try await submission.value()
            guard request.epoch == epoch else { request.continuation.resume(returning: .dropped(stamp, .reset)); return }
            if let packet = result.observations { previousObservations = packet }
            if request.cancellation.isCancelled { request.continuation.resume(returning: .dropped(stamp, .cancelled)) }
            else { request.continuation.resume(returning: .rendered(result.frame)) }
        } catch {
            if request.epoch != epoch { request.continuation.resume(returning: .dropped(request.stamp, .reset)) }
            else if submitted || error is ModelGPUFailure {
                invalidate(reason: .gpuFailure, event: .reset(.gpuFailure))
                request.continuation.resume(throwing: error)
            } else if error is CancellationError { request.continuation.resume(returning: .dropped(request.stamp, .cancelled)) }
            else { request.continuation.resume(throwing: error) }
        }
    }
    // 同时满足本次执行规格与模型有效期；后者还检查源身份、曝光/色温等事实变化。
    private func validDelayed(_ packet: FrameObservations, facts: FrameInputFacts, requirements: ObservationRequirements) -> Bool {
        guard case .delayed(let frames, let seconds) = model.execution.statisticsLatency,
              packet.stamp.index <= facts.stamp.index, facts.stamp.index - packet.stamp.index <= frames,
              facts.stamp.presentationTime - packet.stamp.presentationTime <= seconds else { return false }
        return (try? ObservationValidity.validate(packet, current: facts, requirements: requirements)) != nil
    }
}
