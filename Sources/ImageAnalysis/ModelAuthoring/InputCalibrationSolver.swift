import Foundation
import ImagingCore

/// 一对有限的 [0, 1] 编码 SDR RGB，分别来自输入和独立工作参考。
public struct InputCalibrationPair: Codable, Equatable, Sendable {
    public let input: [Double]
    public let reference: [Double]
    public init(input: [Double], reference: [Double]) { self.input = input; self.reference = reference }
    func validate() throws {
        guard input.count == 3, reference.count == 3,
              (input + reference).allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw LabError.measurement("Input calibration requires finite encoded SDR RGB pairs")
        }
    }
}
/// 输入校准颜色对及其有效配方、参考身份与实测覆盖信息。
public struct LoadedInputCalibrationPairs: Sendable {
    public let pairs: [InputCalibrationPair]
    public let effectiveRecipe: EffectiveInputRecipe
    public let referenceIdentity: String
    public let fileDigests: [String]
    public let conditionRanges: [ConditionRange]
    let measuredFiles: Bool
    let execution: ExecutionProfile?
    /// 注入的数值样本只作为开发证据，即使误差很小也不能授予实拍资格。
    public init(pairs: [InputCalibrationPair], effectiveRecipe: EffectiveInputRecipe, referenceIdentity: String) {
        self.pairs = pairs; self.effectiveRecipe = effectiveRecipe; self.referenceIdentity = referenceIdentity
        fileDigests = []; conditionRanges = []; measuredFiles = false; execution = nil
    }
    init(pairs: [InputCalibrationPair], effectiveRecipe: EffectiveInputRecipe, referenceIdentity: String,
         fileDigests: [String], conditionRanges: [ConditionRange], execution: ExecutionProfile, measuredFiles: Bool) {
        self.pairs = pairs; self.effectiveRecipe = effectiveRecipe; self.referenceIdentity = referenceIdentity
        self.fileDigests = fileDigests; self.conditionRanges = conditionRanges; self.measuredFiles = measuredFiles; self.execution = execution
    }
}
public protocol InputCalibrationPairLoading {
    /// 按集合和样本预算读取颜色对。传入校准时，请求生产路径校正后的输入以供独立验证。
    func load(_ dataset: CalibrationDataset, split: CalibrationSplit, calibration: InputCalibration?, maxSamples: Int) async throws -> LoadedInputCalibrationPairs
}
/// 仅估计线性 RGB 矩阵。白平衡、色调和 LUT 保持固定，拟合目标为独立工作参考。
public struct InputCalibrationSolver {
    private let loader: any InputCalibrationPairLoading
    public init(loader: any InputCalibrationPairLoading) { self.loader = loader }
    /// 仅读取训练集的未校正输入与独立参考，返回带参考内容身份的校准。
    public func solve(_ dataset: CalibrationDataset, reference: WorkingImageContract, options: FitOptions) async throws -> InputCalibration {
        try options.validate()
        guard dataset.project.working == reference else { throw LabError.invalid("Frozen input reference mismatch") }
        let loaded = try await loader.load(dataset, split: .train, calibration: nil, maxSamples: options.maxSamples)
        var calibration = try Self.fit(pairs: loaded.pairs, source: dataset.project.source, effectiveRecipe: loaded.effectiveRecipe, reference: reference, options: options)
        calibration.referenceDigest = loaded.referenceIdentity
        try calibration.validate()
        return calibration
    }
    /// 创建绑定输入源、有效配方和 SDR 工作空间的显式恒等校准。
    public static func identity(source: SourceDescriptor, effectiveRecipe: EffectiveInputRecipe, reference: WorkingImageContract) throws -> InputCalibration {
        try source.validate(); try reference.validate()
        guard reference.dynamicRange == .sdr else { throw LabError.unsupported("Input calibration authoring is SDR only") }
        var result = InputCalibration(id: "unqualified-reference:" + (try reference.digest()), source: source, working: reference)
        result.recipeDigest = try effectiveRecipe.digest()
        return result
    }
    /// 把编码颜色对转换为线性 RGB 后逐输出通道求解。固定矩阵时保留恒等校准。
    public static func fit(pairs: [InputCalibrationPair], source: SourceDescriptor, effectiveRecipe: EffectiveInputRecipe,
                           reference: WorkingImageContract, options: FitOptions) throws -> InputCalibration {
        try options.validate(); try Task.checkCancellation()
        guard !pairs.isEmpty, pairs.count <= options.maxSamples else { throw LabError.measurement("Missing input/reference pairs or sample budget exceeded; select explicit identity if appropriate") }
        for pair in pairs { try pair.validate() }
        var result = try identity(source: source, effectiveRecipe: effectiveRecipe, reference: reference)
        guard options.fixedParameters.allSatisfy({ $0 == "color.matrix" }) else { throw LabError.unsupported("Matrix input solver only supports fixing color.matrix") }
        if !options.fixedParameters.contains("color.matrix") {
            guard options.maxComplexity >= 9 else { throw LabError.measurement("Matrix calibration needs a nine-coefficient complexity budget") }
            let rows = pairs.map { $0.input.map(GenerationMath.linear) }
            var matrix = [Double]()
            for channel in 0..<3 {
                try Task.checkCancellation()
                matrix += try GenerationMath.leastSquares(rows: rows, values: pairs.map { GenerationMath.linear($0.reference[channel]) })
            }
            result.correction.matrix = ColorMatrix3x3(values: matrix)
        }
        try result.validate()
        result.id = "input-matrix-v1:" + (try result.digest())
        return result
    }
}
