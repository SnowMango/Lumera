import Foundation
import Metal
import ImagingCore

/// 已校验并准备到设备上的模型资源，持有用于分配帧槽和驻留预算的账本。
public final class PreparedCameraModel: @unchecked Sendable {
    public let compiled: CompiledCameraModel
    public let execution: ExecutionProfile
    /// 外观资源描述的摘要，用于标记输出采用的资源版本。
    public let resourceDigest: String
    public let resources: ModelResourceSet
    let renderer: LumeraRenderer
    let base: PreparedCameraStyle
    let lutStyles: [String: PreparedCameraStyle]
    let budget: ModelFrameBudget
    private let resourceLease: ModelResourceLease?
    private let inputLock = NSLock()
    private var inputNormalizers: [String: InputNormalizer] = [:]
    /// 在预留帧之前准备输入校正。校正上传、执行变体和仍在持有的照片结果共用此模型的预算。
    public func prepareInputNormalizer(calibration: InputCalibration?, resources: ModelResourceSet) throws -> InputNormalizer {
        guard let calibration else {
            let normalizer = InputNormalizer(renderer: renderer)
            try normalizer.prewarm(calibration: nil, resources: .init(), residency: nil)
            return normalizer
        }
        try calibration.validate()
        guard calibration.resources.count <= 1, calibration.resources.allSatisfy({ $0.role == .correctionLUT }) else {
            throw LabError.unsupported("Input calibration supports one correction LUT")
        }
        guard !calibration.resources.isEmpty else {
            let normalizer = InputNormalizer(renderer: renderer)
            try normalizer.prewarm(calibration: calibration, resources: .init(), residency: nil)
            return normalizer
        }
        // 完整摘要纳入资格声明，避免同一缓存条目返回旧资格。
        let key = try calibration.digest()
        // 缓存查找和预热在同一锁内，避免并发创建重复的常驻校正资源。
        inputLock.lock(); defer { inputLock.unlock() }
        if let cached = inputNormalizers[key] {
            try cached.checkPreparedBinding(calibration: calibration, resources: resources)
            return cached
        }
        var selected: [String: LUTAsset] = [:]
        var resident = 4096 + (try JSON.encode(calibration)).count, workspace = 0
        func addResident(_ bytes: Int) throws {
            guard bytes >= 0, resident <= execution.budget.maxResidentBytes,
                  bytes <= execution.budget.maxResidentBytes - resident else {
                throw LabError.invalid("Input calibration resources exceed model memory budget")
            }
            resident += bytes
        }
        for descriptor in calibration.resources {
            guard let asset = resources.luts[descriptor.id], asset.sha256 == descriptor.sha256 else {
                throw LabError.invalid("Missing or mismatched input calibration resource")
            }
            try asset.preflightDimension(descriptor.dimension)
            let cubeBytes = descriptor.dimension * descriptor.dimension * descriptor.dimension * 16
            let texture = MTLTextureDescriptor(); texture.textureType = .type3D; texture.pixelFormat = .rgba32Float
            texture.width = descriptor.dimension; texture.height = descriptor.dimension; texture.depth = descriptor.dimension
            texture.storageMode = .shared; texture.usage = .shaderRead
            try addResident(renderer.device.heapTextureSizeAndAlign(descriptor: texture).size)
            // Conservatively account immutable source assets even when shared with
            // another variant. Text decoding gets a separate temporary allowance.
            try addResident(asset.cubeText.utf8.count); try addResident(cubeBytes)
            workspace = max(workspace, cubeBytes)
            selected[descriptor.id] = asset
        }
        let lease = try budget.reserveResources(resident: resident, workspace: workspace)
        let normalizer = InputNormalizer(renderer: renderer)
        try normalizer.prewarm(calibration: calibration, resources: ModelResourceSet(luts: selected), residency: lease)
        lease.finishPreparation()
        inputNormalizers[key] = normalizer
        return normalizer
    }
    /// 在准备输入和统计之前取得帧槽，让各阶段使用同一帧预算。
    public func reserveFrame() throws -> FrameReservation { try FrameReservation(model: self) }
    public var preparationStatistics: StylePreparationStatistics { base.preparationStatistics }
    init(compiled: CompiledCameraModel, execution: ExecutionProfile, resources: ModelResourceSet,
         resourceDigest: String, renderer: LumeraRenderer, base: PreparedCameraStyle,
         lutStyles: [String: PreparedCameraStyle], budget: ModelFrameBudget, resourceLease: ModelResourceLease?) {
        self.compiled = compiled; self.execution = execution; self.resources = resources; self.resourceDigest = resourceDigest
        self.renderer = renderer; self.base = base; self.lutStyles = lutStyles
        self.budget = budget; self.resourceLease = resourceLease
    }
}
/// 校验模型的执行能力和资源契约，构建可复用的设备资源。
public final class ModelPreparer {
    /// These kernels currently have no validated continuous-update budget.
    /// Authoring tools use the same capability list as GPU preparation.
    public static let continuousKernelTargets: Set<String> = ["grain.size", "grain.roughness", "halation.radius"]

    /// Device-independent runtime preflight for native authoring. This does not
    /// replace resource-byte, execution-budget or GPU validation during prepare.
    public static func validateModelContract(_ model: CompiledCameraModel) throws {
        guard model.definition.compatibility.requiredCapabilities.isEmpty else {
            throw LabError.unsupported("当前运行管线不支持声明的扩展能力")
        }
        let features = model.definition.observations.features
        guard features.count <= 64, features.allSatisfy({ $0.samplingLongEdge == 256 }) else {
            throw LabError.unsupported("当前统计支持最多 64 项，采样长边固定为 256")
        }
        for program in model.instructions where continuousKernelTargets.contains(program.target) {
            guard program.expression.axes.isEmpty else {
                throw LabError.unsupported("\(program.target)：连续核变化尚无已验证的更新预算，请使用恒定值")
            }
        }
        for descriptor in model.definition.appearance.resources where descriptor.role != .toneCurve {
            guard descriptor.inputDomain == .encodedSRGB, descriptor.outputDomain == .encodedSRGB,
                  descriptor.inputBounds == NumericBounds(lower: 0, upper: 1), descriptor.outOfRange != .reject else {
                throw LabError.unsupported("当前 LUT 支持编码 sRGB、0…1 输入，以及边界值或线性外推")
            }
        }
    }
    private let renderer: LumeraRenderer
    public init(renderer: LumeraRenderer) { self.renderer = renderer }
    /// 以指定执行配置准备独立的模型预算和 GPU 资源。
    public func prepare(_ model: CompiledCameraModel, resources: ModelResourceSet, execution: ExecutionProfile) throws -> PreparedCameraModel {
        try prepare(model, resources: resources, execution: execution, sharing: nil)
    }
    /// 用不同执行配置准备变体，沿用原模型的总内存预算与帧槽。
    public func prepareVariant(of original: PreparedCameraModel, execution: ExecutionProfile) throws -> PreparedCameraModel {
        guard execution.budget == original.execution.budget else { throw LabError.invalid("An execution variant cannot replace its model budget") }
        return try prepare(original.compiled, resources: original.resources, execution: execution, sharing: original.budget)
    }
    private func prepare(_ model: CompiledCameraModel, resources: ModelResourceSet, execution: ExecutionProfile,
                         sharing originalBudget: ModelFrameBudget?) throws -> PreparedCameraModel {
        try execution.validate()
        try Self.validateModelContract(model)
        guard renderer.imageInputFormat == (execution.precision == .float16 ? .rgba16Float : .rgba32Float),
              model.definition.compatibility.dynamicRanges.contains(execution.dynamicRange),
              model.definition.compatibility.requiredCapabilities.isEmpty else { throw LabError.unsupported("Model execution capabilities or precision mismatch") }
        guard EffectResolution.allCases.contains(where: { $0.scale == execution.effectScale }) else { throw LabError.unsupported("Unsupported optical computation scale") }
        // Continuous numerical kernel construction has no declared per-frame CPU budget yet.
        let expectedIDs = Set(model.definition.appearance.resources.map(\.id))
        guard Set(resources.luts.keys).union(resources.curves.keys) == expectedIDs else { throw LabError.invalid("Model resources must match declared IDs exactly") }
        var resourceBytes = 0, largestDecodeWorkspace = 0
        for descriptor in model.definition.appearance.resources {
            if descriptor.role == .toneCurve { resourceBytes += descriptor.dimension * 16; continue }
            largestDecodeWorkspace = max(largestDecodeWorkspace, descriptor.dimension * descriptor.dimension * descriptor.dimension * 16)
            let texture = MTLTextureDescriptor(); texture.textureType = .type3D; texture.pixelFormat = .rgba32Float
            texture.width = descriptor.dimension; texture.height = descriptor.dimension; texture.depth = descriptor.dimension
            texture.storageMode = .shared; texture.usage = .shaderRead
            let required = renderer.device.heapTextureSizeAndAlign(descriptor: texture).size
            guard required <= execution.budget.maxResidentBytes - resourceBytes else { throw LabError.invalid("Model resources exceed memory budget") }
            resourceBytes += required
            if let asset = resources.luts[descriptor.id] {
                guard (asset.cubeText.utf8.count + descriptor.dimension * descriptor.dimension * descriptor.dimension * 16) <= execution.budget.maxResidentBytes - resourceBytes else { throw LabError.invalid("Model source resources exceed memory budget") }
                resourceBytes += (asset.cubeText.utf8.count + descriptor.dimension * descriptor.dimension * descriptor.dimension * 16)
            }
        }
        // Validated cubes remain alive for neutral-mixture verification while the
        // uploader may parse one text cube again. This workspace exists only during
        // preparation, before any frame reservation can be issued.
        guard largestDecodeWorkspace <= execution.budget.maxResidentBytes - resourceBytes else { throw LabError.invalid("Model preparation decode workspace exceeds memory budget") }
        let budget: ModelFrameBudget
        let resourceLease: ModelResourceLease?
        if let originalBudget {
            budget = try ModelFrameBudget(execution: execution, sharing: originalBudget)
            // Reserve before parsing/uploading; decode scratch is released after preparation.
            resourceLease = try budget.reserveResources(resident: resourceBytes, workspace: largestDecodeWorkspace)
        } else {
            budget = try ModelFrameBudget(execution: execution, resourceBytes: resourceBytes)
            resourceLease = nil
        }
        var parameters = model.definition.appearance.parameters, weights = model.definition.appearance.lutWeights
        for program in model.instructions {
            if case .constant(let value) = program.expression { try ControlAccess.apply(value, target: program.target, parameters: &parameters, lutWeights: &weights) }
        }
        let style = try ResolvedStyle(parameters: parameters, profileDigest: model.identity, temporalPolicy: model.temporalPolicy)
        let base = try renderer.prepare(style)
        // Even zero-amplitude effects can be activated by a response or permitted edit.
        if parameters.halation.enabled { _ = base.executionPlan.halation(for: parameters.halation) }
        if parameters.grain.enabled { _ = base.executionPlan.grain(for: parameters.grain) }
        var lutStyles: [String: PreparedCameraStyle] = [:]
        var cubes: [String: CubeLUT] = [:]
        for descriptor in model.definition.appearance.resources {
            if descriptor.role == .toneCurve {
                guard let curve = resources.curves[descriptor.id], try Digest.data(JSON.encode(curve)) == descriptor.sha256,
                      curve.knots.count == descriptor.dimension,
                      descriptor.outputBounds.contains(curve.outputRange.lowerBound), descriptor.outputBounds.contains(curve.outputRange.upperBound) else { throw LabError.invalid("Curve resource does not match descriptor") }
                continue
            }
            guard descriptor.role == .styleLUT, var asset = resources.luts[descriptor.id], asset.sha256 == descriptor.sha256,
                  descriptor.inputDomain == .encodedSRGB, descriptor.outputDomain == .encodedSRGB,
                  descriptor.inputBounds == NumericBounds(lower: 0, upper: 1) else { throw LabError.invalid("Model LUT content or domain mismatch") }
            let cube = try asset.decodedCube()
            guard cube.size == descriptor.dimension, cube.rgba.enumerated().allSatisfy({ $0.offset % 4 == 3 || ($0.element.isFinite && (0...1).contains($0.element) && descriptor.outputBounds.contains(Double($0.element))) }) else { throw LabError.invalid("Model LUT dimension or output range mismatch") }
            cubes[descriptor.id] = cube
            guard model.lutResourceIDs.contains(descriptor.id) else { continue }
            switch descriptor.outOfRange {
            case .clamp: asset.boundaryPolicy = .clamp
            case .linearExtrapolation: asset.boundaryPolicy = .extrapolate
            case .reject: throw LabError.unsupported("Reject-boundary LUT requires a proven intermediate domain")
            }
            let prepared = try renderer.prepare(style, lut: asset)
            if parameters.halation.enabled { _ = prepared.executionPlan.halation(for: parameters.halation) }
            if parameters.grain.enabled { _ = prepared.executionPlan.grain(for: parameters.grain) }
            lutStyles[descriptor.id] = prepared
        }
        if let strength = model.definition.edits.strength, !strength.neutralLUTWeights.isEmpty {
            let active = strength.neutralLUTWeights.filter { $0.weight > 0 }
            guard let first = active.first, let reference = cubes[first.resourceID] else { throw LabError.invalid("Missing neutral LUT palette") }
            if execution.dynamicRange == .edr, model.definition.appearance.resources.contains(where: { descriptor in active.contains(where: { $0.resourceID == descriptor.id }) && descriptor.outOfRange == .clamp }) {
                throw LabError.unsupported("Clamped neutral LUT identity is verified only on 0...1, not the extended range")
            }
            if execution.dynamicRange == .edr, !active.allSatisfy({ lutStyles[$0.resourceID]?.hasExactIdentityLUT == true }) {
                throw LabError.unsupported("Extended neutral LUT mixtures require exact identity component tables or a bounded extended-domain proof")
            }
            let total = active.reduce(Float(0)) { $0 + Float($1.weight) }
            // 相同尺寸和边界语义下，三线性插值与加权混合可交换，因此逐点验证完整网格。
            for b in 0..<reference.size { for g in 0..<reference.size { for r in 0..<reference.size {
                let index = ((b * reference.size + g) * reference.size + r) * 4
                for (channel, coordinate) in [r,g,b].enumerated() {
                    let actual = active.reduce(Float(0)) { $0 + Float($1.weight) * cubes[$1.resourceID]!.rgba[index + channel] } / total
                    guard abs(actual - Float(coordinate) / Float(reference.size - 1)) <= 1e-6 else { throw LabError.invalid("Neutral weighted LUT endpoint is not identity") }
                }
            } } }
        }
        let prepared = try PreparedCameraModel(compiled: model, execution: execution, resources: resources,
            resourceDigest: Digest.data(JSON.encode(model.definition.appearance.resources)), renderer: renderer,
            base: base, lutStyles: lutStyles, budget: budget, resourceLease: resourceLease)
        resourceLease?.finishPreparation()
        return prepared
    }
}

/// 跨输入准备和统计阶段的单帧预留，可转交给一个执行计划或提前取消。
public final class FrameReservation: @unchecked Sendable {
    /// 执行配置副本，预算收窄到当前帧实际取得的份额。
    public let execution: ExecutionProfile
    let model: PreparedCameraModel
    let lease: FrameBudgetLease
    private let lock = NSLock()
    private var issued = false
    init(model: PreparedCameraModel) throws {
        self.model = model; lease = try model.budget.acquire(retainedInputBytes: 0)
        var execution = model.execution; execution.budget.maxResidentBytes = lease.allowance
        execution.budget.maxInFlightFrames = 1; self.execution = execution
    }
    func issue(inputBytes: Int) throws {
        lock.lock(); defer { lock.unlock() }
        guard !issued else { throw LabError.invalid("Frame reservation already issued or cancelled") }
        try lease.retainInput(bytes: inputBytes); issued = true
    }
    /// 放弃未转交的预留。已转交后由计划管理。
    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        guard !issued else { return }; issued = true; lease.completeGPU()
    }
}

/// 统一记录模型内的输入、输出和临时工作预算。宿主采集队列及独立渲染任务各有预算。
final class ModelFrameBudget: @unchecked Sendable {
    /// 执行变体共用同一本账和同一把锁，按各自配置计算最低帧内存。
    private final class Ledger: @unchecked Sendable {
        let totalBytes: Int, slots: Int
        let lock = NSLock()
        var active = 0, reserved = 0
        init(totalBytes: Int, slots: Int) { self.totalBytes = totalBytes; self.slots = slots }
    }
    private let ledger: Ledger
    private let minimumFrameBytes: Int
    init(execution: ExecutionProfile, resourceBytes: Int) throws {
        ledger = Ledger(totalBytes: max(0, execution.budget.maxResidentBytes - resourceBytes), slots: execution.budget.maxInFlightFrames)
        minimumFrameBytes = try Self.minimum(execution, total: ledger.totalBytes, slots: ledger.slots)
    }
    init(execution: ExecutionProfile, sharing original: ModelFrameBudget) throws {
        ledger = original.ledger
        minimumFrameBytes = try Self.minimum(execution, total: ledger.totalBytes, slots: ledger.slots)
    }
    private static func minimum(_ execution: ExecutionProfile, total: Int, slots: Int) throws -> Int {
        let pixels = try ImageDimensions.pixelCount(width: execution.width, height: execution.height)
        guard total / slots / execution.precision.bytesPerPixel / 4 >= pixels else { throw LabError.invalid("Model has no bounded frame working set") }
        return pixels * execution.precision.bytesPerPixel * 4
    }
    func acquire(retainedInputBytes: Int) throws -> FrameBudgetLease {
        ledger.lock.lock(); defer { ledger.lock.unlock() }
        guard ledger.active < ledger.slots else { throw LabError.invalid("Model in-flight budget exhausted") }
        let allowance = (ledger.totalBytes - ledger.reserved) / (ledger.slots - ledger.active)
        guard allowance >= minimumFrameBytes, allowance > retainedInputBytes else { throw LabError.invalid("Retained outputs exhaust model memory budget") }
        ledger.reserved += allowance; ledger.active += 1
        return FrameBudgetLease(owner: self, allowance: allowance, inputBytes: retainedInputBytes)
    }
    func reserveResources(resident: Int, workspace: Int) throws -> ModelResourceLease {
        ledger.lock.lock(); defer { ledger.lock.unlock() }
        let available = ledger.totalBytes - ledger.reserved
        guard resident <= available, workspace <= available - resident,
              minimumFrameBytes <= available - resident else { throw LabError.invalid("Execution variant resources exceed the shared model budget") }
        ledger.reserved += resident + workspace
        return ModelResourceLease(owner: self, resident: resident, workspace: workspace)
    }
    fileprivate func releaseResources(_ bytes: Int) {
        ledger.lock.lock(); defer { ledger.lock.unlock() }; ledger.reserved -= bytes
    }
    fileprivate func complete(reservation: Int, retained: Int) {
        ledger.lock.lock(); defer { ledger.lock.unlock() }; ledger.active -= 1; ledger.reserved -= reservation - retained
    }
    fileprivate func release(bytes: Int, active wasActive: Bool) {
        ledger.lock.lock(); defer { ledger.lock.unlock() }; ledger.reserved -= bytes; if wasActive { ledger.active -= 1 }
    }
}
/// 临时解码空间在准备结束时归还，常驻份额随校正或变体资源释放。
final class ModelResourceLease: @unchecked Sendable {
    private let owner: ModelFrameBudget
    private let resident: Int
    private var workspace: Int
    init(owner: ModelFrameBudget, resident: Int, workspace: Int) { self.owner = owner; self.resident = resident; self.workspace = workspace }
    func finishPreparation() { owner.releaseResources(workspace); workspace = 0 }
    deinit { owner.releaseResources(resident + workspace) }
}
/// GPU 完成后归还帧槽和临时预算。租约继续计入存活的输入和独立输出，直至释放。
final class FrameBudgetLease: @unchecked Sendable {
    private let owner: ModelFrameBudget
    let allowance: Int
    private let lock = NSLock()
    private var retained: Int
    private var retainedInput: Int
    private var completed = false
    init(owner: ModelFrameBudget, allowance: Int, inputBytes: Int) {
        self.owner = owner; self.allowance = allowance; retained = inputBytes; retainedInput = inputBytes
    }
    func retainInput(bytes: Int) throws {
        lock.lock(); defer { lock.unlock() }
        guard !completed, bytes >= 0, bytes <= allowance - retained else { throw LabError.invalid("Retained input exceeds frame reservation") }
        retained += bytes; retainedInput += bytes
    }
    func retainOutput(bytes: Int) throws {
        lock.lock(); defer { lock.unlock() }
        guard !completed, bytes <= allowance - retained else { throw LabError.invalid("Owned output exceeds frame reservation") }
        retained += bytes
    }
    /// 提交方放弃尚未提交的命令后调用。计划仍持有输入，此时没有已交付的独立输出。
    func abortUnsubmitted() {
        lock.lock(); defer { lock.unlock() }
        guard !completed else { return }
        retained = retainedInput
        owner.complete(reservation: allowance, retained: retained); completed = true
    }
    func completeGPU() {
        lock.lock(); defer { lock.unlock() }
        if !completed { owner.complete(reservation: allowance, retained: retained); completed = true }
    }
    deinit { owner.release(bytes: completed ? retained : allowance, active: !completed) }
}
