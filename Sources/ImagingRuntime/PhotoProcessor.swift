import Foundation
import CoreGraphics
import ImagingCore
import ImageRendering

/// Stateless across photos. Automatic history is never shared with a camera preview/session.
public final class PhotoProcessor: @unchecked Sendable {
    private let owner = UUID()
    private let renderer: LumeraRenderer
    private let working: WorkingImageContract
    private let inputResources: ModelResourceSet
    /// 建立照片处理协调器；inputResources 仅存放输入校正资源，目标风格资源由 model 持有。
    public init(renderer: LumeraRenderer, working: WorkingImageContract, inputResources: ModelResourceSet? = nil) throws {
        _ = try InputAdapter(renderer: renderer, working: working)
        self.renderer = renderer; self.working = working
        self.inputResources = try inputResources ?? ModelResourceSet()
    }
    /// 从原始来源建立完整照片的独立自动决策，并等待拥有型输出完成。
    /// 顺序为输入解释 → 一次校正 → 全图观测 → 自动求值 → 用户编辑 → 渲染。
    /// calibration 为 nil 时使用明确未验证的恒等输入参考；此调用不继承视频适应历史。
    /// 真正更换输入或裁剪成新照片时应重新调用此方法，而非复用旧快照。
    public func process(_ source: SourceImage, descriptor: SourceDescriptor, recipe: InputRecipe,
                        calibration: InputCalibration?, model: PreparedCameraModel, edits: EditRequest = .init(), stamp: FrameStamp,
                        targetConditions: CaptureConditions = .init(), rawOverrides: [RAWOverride] = [], seed: UInt32 = 42,
                        tiled: Bool = false) async throws -> PhotoResult {
        try Task.checkCancellation(); try stamp.validate()
        // 先登记常驻校正资源，再取得帧额度，避免多精度导出绕过共享预算。
        let normalizer = try model.prepareInputNormalizer(calibration: calibration, resources: inputResources)
        let reservation = try model.reserveFrame()
        defer { reservation.cancel() }
        let lease = try PhotoSourceLease(source)
        let adapter = try InputAdapter(renderer: renderer, working: working)
        let normalized = try await adapter.prepare(source, descriptor: descriptor, recipe: recipe, execution: reservation.execution, rawOverrides: rawOverrides)
        let input = try await normalizer.normalize(normalized, calibration: calibration, resources: inputResources)
        try lease.validate()
        let observations = try await renderer.observe(input, stamp: stamp, requirements: model.compiled.definition.observations)
        let automatic = try CameraModelEvaluator.evaluate(model.compiled, context: .init(evaluationStamp: stamp, observations: observations, targetConditions: targetConditions))
        let resolved = try EditResolver.resolve(edits, automatic: automatic, model: model.compiled)
        let plan = try RenderPlanner().plan(resolved, input: input, model: model, stamp: stamp, seed: seed, reservation: reservation)
        let frame = try await (tiled ? renderer.renderTiled(input, plan: plan) : renderer.render(input, plan: plan))
        let snapshot = PhotoDecisionSnapshot(input: input, observations: observations, automatic: automatic, owner: owner,
            model: model, renderer: renderer, source: lease, descriptor: descriptor, recipe: recipe, calibration: calibration,
            inputResources: inputResources, rawOverrides: rawOverrides, reservation: reservation, stamp: stamp, seed: seed)
        let decision = FrameDecision(stamp: stamp, modelDigest: model.compiled.identity, inputDigest: input.inputID,
            resourceDigest: model.resourceDigest, observations: observations, edits: edits, controls: resolved, seed: seed)
        return .init(frame: frame, snapshot: snapshot, decision: decision)
    }
    /// Reuses the full-input decision. Precision changes redevelop the original source, never promote half pixels.
    /// 仅改变编辑参数、输出规格或视口；自动外观仍由快照中的完整输入决定。
    /// region 使用输出图像的 Core Image 像素坐标；改变动态范围、预算或输入内容须新建决策。
    /// 精度变化会重新读取/显影原始源，不能从既有 Half 像素恢复 Float32 精度。
    public func render(_ snapshot: PhotoDecisionSnapshot, edits: EditRequest = .init(), region: CGRect? = nil,
                       execution: ExecutionProfile, tiled: Bool = false) async throws -> RenderedFrame {
        try Task.checkCancellation(); try execution.validate()
        guard snapshot.owner == owner, snapshot.modelID == snapshot.model.compiled.identity,
              snapshot.input.working == working, execution.dynamicRange == snapshot.model.execution.dynamicRange else {
            throw LabError.invalid("Snapshot belongs to another processor/model/reference; dynamic-range changes require a new decision")
        }
        try snapshot.source.validate()
        let (renderer, model) = try snapshot.executionVariant(execution)
        let normalizer = execution.precision == snapshot.input.execution.precision ? nil :
            try model.prepareInputNormalizer(calibration: snapshot.calibration, resources: snapshot.inputResources)
        let reservation = try model.reserveFrame(); defer { reservation.cancel() }
        let input: PreparedInput
        if execution.precision == snapshot.input.execution.precision { input = snapshot.input }
        else {
            let normalized = try await InputAdapter(renderer: renderer, working: working).prepare(snapshot.source.source,
                descriptor: snapshot.descriptor, recipe: snapshot.recipe, execution: reservation.execution, rawOverrides: snapshot.rawOverrides)
            input = try await normalizer!.normalize(normalized, calibration: snapshot.calibration, resources: snapshot.inputResources)
            try snapshot.source.validate()
            guard input.sourceID == snapshot.input.sourceID, input.calibrationID == snapshot.input.calibrationID else {
                throw LabError.invalid("Reprepared source recipe/calibration changed; create a new decision")
            }
        }
        let resolved = try EditResolver.resolve(edits, automatic: snapshot.automatic, model: model.compiled)
        let plan = try RenderPlanner().plan(resolved, input: input, model: model, stamp: snapshot.stamp, seed: snapshot.seed, reservation: reservation)
        return try await (region != nil || tiled ? renderer.renderTiled(input, plan: plan, region: region) : renderer.render(input, plan: plan))
    }
}
