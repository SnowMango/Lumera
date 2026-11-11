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
                        calibration: InputCalibration?, model: PreparedStyleModel, edits: EditRequest = .init(), stamp: FrameStamp,
                        targetConditions: CaptureConditions = .init(), rawOverrides: [RAWOverride] = [], seed: UInt32 = 42,
                        tiled: Bool = false) async throws -> PhotoResult {
        try await process(source, descriptor: descriptor, recipe: recipe, calibration: calibration, model: model, edits: edits, stamp: stamp,
                          targetConditions: targetConditions, rawOverrides: rawOverrides, seed: seed, tiled: tiled, rawConfiguration: nil)
    }

    /// Retains the original source and RAW configuration for precision changes and replay.
    public func process(_ source: SourceImage, descriptor: SourceDescriptor, recipe: InputRecipe,
                        calibration: InputCalibration?, model: PreparedStyleModel, edits: EditRequest = .init(), stamp: FrameStamp,
                        targetConditions: CaptureConditions = .init(), rawOverrides: [RAWOverride] = [], seed: UInt32 = 42,
                        tiled: Bool = false, rawConfiguration: RAWDevelopmentConfiguration?) async throws -> PhotoResult {
        try Task.checkCancellation(); try stamp.validate()
        try InputAdapter.validateRAWRequest(source, descriptor: descriptor, recipe: recipe, rawOverrides: rawOverrides, rawConfiguration: rawConfiguration)
        // 先登记常驻校正资源，再取得帧额度，避免多精度导出绕过共享预算。
        let normalizer = try model.prepareInputNormalizer(calibration: calibration, resources: inputResources)
        let reservation = try model.reserveFrame()
        defer { reservation.cancel() }
        let lease = try PhotoSourceLease(source)
        let adapter = try InputAdapter(renderer: renderer, working: working)
        let normalized = try await adapter.prepare(lease.source, descriptor: descriptor, recipe: recipe, execution: reservation.execution,
                                                   rawOverrides: rawOverrides, rawConfiguration: rawConfiguration)
        let input = try await normalizer.normalize(normalized, calibration: calibration, resources: inputResources)
        try lease.validate()
        let observations = try await renderer.observe(input, stamp: stamp, requirements: model.compiled.definition.observations)
        let automatic = try StyleModelEvaluator.evaluate(model.compiled, context: .init(evaluationStamp: stamp, observations: observations, targetConditions: targetConditions))
        let resolved = try EditResolver.resolve(edits, automatic: automatic, model: model.compiled)
        let plan = try RenderPlanner().plan(resolved, input: input, model: model, stamp: stamp, seed: seed, reservation: reservation)
        let frame = try await (tiled ? renderer.renderTiled(input, plan: plan) : renderer.render(input, plan: plan))
        let snapshot = PhotoDecisionSnapshot(input: input, observations: observations, automatic: automatic, owner: owner,
            model: model, renderer: renderer, source: lease, descriptor: descriptor, recipe: recipe, calibration: calibration,
            inputResources: inputResources, rawOverrides: rawOverrides, rawConfiguration: rawConfiguration,
            reservation: reservation, stamp: stamp, seed: seed)
        let decision = FrameDecision(stamp: stamp, modelDigest: model.compiled.identity, inputDigest: input.inputID,
            resourceDigest: model.resourceDigest, observations: observations, edits: edits, controls: resolved, seed: seed)
        return .init(frame: frame, snapshot: snapshot, decision: decision)
    }
    /// Reuses the full-input decision. Precision changes prepare the retained source again.
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
                descriptor: snapshot.descriptor, recipe: snapshot.recipe, execution: reservation.execution,
                rawOverrides: snapshot.rawOverrides, rawConfiguration: snapshot.rawConfiguration)
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

extension PhotoProcessor {
    /// Retain a new source revision independently of any target model.
    public func makeSource(_ source: SourceImage, descriptor: SourceDescriptor, recipe: InputRecipe,
                           calibration: InputCalibration?, rawOverrides: [RAWOverride] = [],
                           rawConfiguration: RAWDevelopmentConfiguration? = nil) throws -> PhotoSource {
        try PhotoSource(source, descriptor: descriptor, recipe: recipe, working: working, calibration: calibration,
                        inputResources: inputResources, rawOverrides: rawOverrides, rawConfiguration: rawConfiguration)
    }

    /// Apply a fresh model decision to the source. An earlier decision can supply compatible observations.
    public func process(_ source: PhotoSource, cache: PhotoInputCache, model: PreparedStyleModel,
                        edits: EditRequest = .init(), stamp: FrameStamp, targetConditions: CaptureConditions = .init(),
                        seed: UInt32 = 42, tiled: Bool = false, retention: PhotoInputRetention = .retain,
                        reusing previous: PhotoSessionSnapshot? = nil) async throws -> PhotoSessionResult {
        try Task.checkCancellation()
        try stamp.validate()
        try source.lease.validate()
        let entry = try await acquire(source, cache: cache, model: model, retention: retention)
        defer { withExtendedLifetime(entry) {} }
        let residency = try entry.residency(for: model)
        let input = residency.input
        let reservation = try model.reserveFrame(for: residency)
        defer { reservation.cancel() }

        let requirements = model.compiled.definition.observations
        let observations: FrameObservations
        if let previous, previous.source === source, previous.stamp == stamp,
           previous.model.execution.precision == model.execution.precision,
           previous.model.renderer.device.registryID == model.renderer.device.registryID,
           previous.model.compiled.definition.observations == requirements, try previous.matches(input) {
            observations = previous.observations
        } else {
            observations = try await model.renderer.observe(input, stamp: stamp, requirements: requirements, reservation: reservation)
        }
        let automatic = try StyleModelEvaluator.evaluate(model.compiled,
            context: .init(evaluationStamp: stamp, observations: observations, targetConditions: targetConditions))
        let resolved = try EditResolver.resolve(edits, automatic: automatic, model: model.compiled)
        let frame = try await render(input, model: model, resolved: resolved, stamp: stamp, seed: seed,
                                     reservation: reservation, region: nil, tiled: tiled)
        let snapshot = try PhotoSessionSnapshot(source: source, inputFacts: input.photoFacts(stamp: stamp),
            inputWidth: input.width, inputHeight: input.height, observations: observations, automatic: automatic,
            owner: owner, model: model, seed: seed)
        let decision = FrameDecision(stamp: stamp, modelDigest: model.compiled.identity, inputDigest: input.inputID,
            resourceDigest: model.resourceDigest, observations: observations, edits: edits, controls: resolved, seed: seed)
        return PhotoSessionResult(frame: frame, snapshot: snapshot, decision: decision)
    }

    /// Replay a photo decision from retained source pixels, rebuilding at the requested precision as needed.
    public func render(_ snapshot: PhotoSessionSnapshot, cache: PhotoInputCache, execution: ExecutionProfile,
                       edits: EditRequest = .init(), region: CGRect? = nil, tiled: Bool = false,
                       retention: PhotoInputRetention = .retain) async throws -> RenderedFrame {
        try Task.checkCancellation()
        try execution.validate()
        guard snapshot.owner == owner, execution.dynamicRange == snapshot.source.working.dynamicRange else {
            throw LabError.invalid("Photo snapshot belongs to another processor or dynamic range")
        }
        try snapshot.source.lease.validate()
        let (_, model) = try snapshot.variants.get(execution)
        let entry = try await acquire(snapshot.source, cache: cache, model: model, retention: retention)
        defer { withExtendedLifetime(entry) {} }
        let residency = try entry.residency(for: model)
        guard try snapshot.matches(residency.input) else {
            throw LabError.invalid("Reprepared source recipe, geometry or calibration changed; create a new decision")
        }
        let reservation = try model.reserveFrame(for: residency)
        defer { reservation.cancel() }
        let resolved = try EditResolver.resolve(edits, automatic: snapshot.automatic, model: model.compiled)
        return try await render(residency.input, model: model, resolved: resolved, stamp: snapshot.stamp, seed: snapshot.seed,
                                reservation: reservation, region: region, tiled: tiled)
    }

    private func acquire(_ source: PhotoSource, cache: PhotoInputCache, model: PreparedStyleModel,
                         retention: PhotoInputRetention) async throws -> PhotoInputLease {
        guard source.working == working, model.execution.dynamicRange == working.dynamicRange else {
            throw LabError.invalid("Photo source and model must use the processor's working range and reference")
        }
        return try await cache.acquire(PhotoInputKey(source: source, model: model), retention: retention) {
            let normalizer = try model.prepareInputNormalizer(calibration: source.calibration, resources: source.inputResources)
            let reservation = try model.reserveFrame()
            defer { reservation.cancel() }
            let normalized = try await InputAdapter(renderer: model.renderer, working: source.working).prepare(source.lease.source,
                descriptor: source.descriptor, recipe: source.recipe, execution: reservation.execution,
                rawOverrides: source.rawOverrides, rawConfiguration: source.rawConfiguration)
            let input = try await normalizer.normalize(normalized, calibration: source.calibration, resources: source.inputResources)
            try source.lease.validate()
            return try reservation.finishPreparingPhotoInput(input)
        }
    }

    private func render(_ input: PreparedInput, model: PreparedStyleModel, resolved: ResolvedControls, stamp: FrameStamp,
                        seed: UInt32, reservation: FrameReservation, region: CGRect?, tiled: Bool) async throws -> RenderedFrame {
        let plan = try RenderPlanner().plan(resolved, input: input, model: model, stamp: stamp, seed: seed, reservation: reservation)
        defer { plan.cancel() }
        if region != nil || tiled { return try await model.renderer.renderTiled(input, plan: plan, region: region) }
        return try await model.renderer.render(input, plan: plan)
    }
}


extension PhotoProcessor {
    /// Bounded original-source preparation, full-frame decision and awaited tile output.
    /// The returned value snapshot retains no prepared pixels. Decoder memory remains opaque.
    public func processStreaming(_ source: PhotoSource, model: PreparedStyleModel,
                                 edits: EditRequest = .init(), stamp: FrameStamp,
                                 targetConditions: CaptureConditions = .init(), seed: UInt32 = 42,
                                 sink: (PhotoTile) async throws -> Void) async throws -> PhotoSessionSnapshot {
        guard source.working == working else { throw LabError.invalid("Photo source working contract differs") }
        try source.lease.validate()
        let resolved = try InputAdapter(renderer: model.renderer, working: working).resolve(source.lease.source,
            descriptor: source.descriptor, recipe: source.recipe, execution: model.execution,
            rawOverrides: source.rawOverrides, rawConfiguration: source.rawConfiguration)
        let result = try await model.renderer.streamPhoto(resolved, model: model, calibration: source.calibration,
            inputResources: source.inputResources, edits: edits, stamp: stamp, targetConditions: targetConditions, seed: seed) { tile in
                try source.lease.validate(); try await sink(tile)
            }
        try source.lease.validate()
        return PhotoSessionSnapshot(source: source, inputFacts: result.inputFacts, inputWidth: resolved.width, inputHeight: resolved.height,
            observations: result.observations, automatic: result.controls.automatic, owner: owner, model: model, seed: seed)
    }

    /// Replay the same automatic decision for a preview, viewport or original-resolution export.
    public func renderStreaming(_ snapshot: PhotoSessionSnapshot, execution: ExecutionProfile,
                                edits: EditRequest = .init(), region: CGRect? = nil,
                                sink: (PhotoTile) async throws -> Void) async throws -> PhotoStreamResult {
        guard snapshot.owner == owner, execution.dynamicRange == working.dynamicRange else { throw LabError.invalid("Snapshot reference differs") }
        let source = snapshot.source
        try source.lease.validate()
        let (_, model) = try snapshot.variants.get(execution, streaming: true)
        let resolved = try InputAdapter(renderer: model.renderer, working: working).resolve(source.lease.source,
            descriptor: source.descriptor, recipe: source.recipe, execution: execution,
            rawOverrides: source.rawOverrides, rawConfiguration: source.rawConfiguration)
        guard resolved.width == snapshot.inputWidth, resolved.height == snapshot.inputHeight else { throw LabError.invalid("Source geometry changed") }
        let result = try await model.renderer.streamPhoto(resolved, model: model, calibration: source.calibration,
            inputResources: source.inputResources, edits: edits, stamp: snapshot.stamp, seed: snapshot.seed, region: region,
            reusing: snapshot.observations, automatic: snapshot.automatic) { tile in
                try source.lease.validate(); try await sink(tile)
            }
        try source.lease.validate()
        return result
    }
}
