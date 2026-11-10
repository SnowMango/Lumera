import Foundation
import CryptoKit
import ImagingCore
import ImageRendering

/// Full-input decision and source lease. Region/viewport changes never create observations.
/// Externally backed CIImage/CVPixelBuffer sources must remain immutable while this snapshot exists.
/// Retaining a camera pixel buffer prevents its pool from recycling it; callers must not mutate it.
public final class PhotoDecisionSnapshot: @unchecked Sendable {
    /// 已完成一次输入校正的全图像素；保留此对象也保留对应输入存储。
    public let input: PreparedInput
    /// 来自完整输入的观测包，不随视口移动或分块输出重新统计。
    public let observations: FrameObservations
    /// 用户编辑之前的自动结果；后续编辑以此为基准，不累积叠加上一次编辑。
    public let automatic: AutomaticControls
    /// 编译模型的内容身份，用于拒绝跨模型复用快照。
    public let modelID: String
    /// 原输入的时间/序号身份；导出与区域重绘不重新编号。
    public let stamp: FrameStamp
    /// 冻结的随机种子，供同一照片的重绘与导出复现纹理。
    public let seed: UInt32
    /// The retained source contains original RAW bytes, either directly or at a validated URL.
    public var canRedevelopRAW: Bool { source.source.inputDevelopment == .rawDevelopment }
    let owner: UUID
    let model: PreparedCameraModel
    let renderer: LumeraRenderer
    let source: PhotoSourceLease
    let descriptor: SourceDescriptor
    let recipe: InputRecipe
    let calibration: InputCalibration?
    let inputResources: ModelResourceSet
    let rawOverrides: [RAWOverride]
    let rawConfiguration: RAWDevelopmentConfiguration?
    let reservation: FrameReservation
    private let variants: PhotoExecutionVariants

    func executionVariant(_ execution: ExecutionProfile) throws -> (renderer: LumeraRenderer, model: PreparedCameraModel) {
        try variants.get(execution)
    }
    init(input: PreparedInput, observations: FrameObservations, automatic: AutomaticControls,
         owner: UUID, model: PreparedCameraModel, renderer: LumeraRenderer, source: PhotoSourceLease,
         descriptor: SourceDescriptor, recipe: InputRecipe, calibration: InputCalibration?, inputResources: ModelResourceSet,
         rawOverrides: [RAWOverride], rawConfiguration: RAWDevelopmentConfiguration?, reservation: FrameReservation, stamp: FrameStamp, seed: UInt32) {
        self.input = input; self.observations = observations; self.automatic = automatic
        self.owner = owner; self.model = model; self.renderer = renderer; self.source = source
        self.descriptor = descriptor; self.recipe = recipe; self.calibration = calibration; self.inputResources = inputResources
        self.rawOverrides = rawOverrides; self.reservation = reservation; self.stamp = stamp; self.seed = seed
        self.rawConfiguration = rawConfiguration
        modelID = model.compiled.identity
        variants = PhotoExecutionVariants(model: model, renderer: renderer)
    }
}
/// 一次照片处理的完成输出、可再编辑快照与最终参数记录。
public struct PhotoResult: Sendable {
    public let frame: RenderedFrame
    public let snapshot: PhotoDecisionSnapshot
    public let decision: FrameDecision
}
/// 保留原始源以支持重新显影；文件逐字节摘要检查防止路径未变但内容已替换。
struct PhotoSourceLease: @unchecked Sendable {
    let source: SourceImage
    private let fileDigest: String?
    init(_ source: SourceImage) throws {
        self.source = source
        if case .rawURL(let url) = source { fileDigest = try Self.digest(url) } else { fileDigest = nil }
    }
    func validate() throws {
        if case .rawURL(let url) = source, try Self.digest(url) != fileDigest { throw LabError.invalid("Photo source bytes changed; create a new decision") }
    }
    // 分块读取只约束哈希工作区；内存图像/像素缓冲的不可变性仍由宿主保证。
    private static func digest(_ url: URL) throws -> String {
        guard url.isFileURL else { throw LabError.invalid("Photo replay requires a local source") }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { try Task.checkCancellation(); hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Input-independent model execution variants shared by both photo APIs.
final class PhotoExecutionVariants: @unchecked Sendable {
    private let model: PreparedCameraModel
    private let renderer: LumeraRenderer

    init(model: PreparedCameraModel, renderer: LumeraRenderer) {
        self.model = model
        self.renderer = renderer
    }

    private let variantLock = NSLock()
    // 以完整执行规格缓存变体；不同精度的渲染器仍共用原模型预算账本。
    private var variants: [(execution: ExecutionProfile, renderer: LumeraRenderer, model: PreparedCameraModel)] = []
    /// Serialize cache misses so concurrent exports cannot upload duplicate variants.
    func get(_ execution: ExecutionProfile, streaming: Bool = false) throws -> (renderer: LumeraRenderer, model: PreparedCameraModel) {
        guard execution.budget == model.execution.budget else { throw LabError.invalid("Snapshot budget changes require a new model and photo decision") }
        if execution == model.execution { return (renderer, model) }
        variantLock.lock(); defer { variantLock.unlock() }
        if let cached = variants.first(where: { $0.execution == execution }) { return (cached.renderer, cached.model) }
        let selectedRenderer = execution.precision == model.execution.precision ? renderer : try LumeraRenderer(device: renderer.device, precision: .init(execution.precision))
        let selectedModel = try ModelPreparer(renderer: selectedRenderer).prepareVariant(of: model, execution: execution, streaming: streaming)
        variants.append((execution, selectedRenderer, selectedModel))
        return (selectedRenderer, selectedModel)
    }
}
