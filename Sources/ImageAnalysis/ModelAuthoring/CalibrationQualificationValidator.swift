import Foundation
import ImagingCore

/// 独立输入颜色测量。误差为归一化编码 RGB 的最大通道绝对差，样本数按颜色对计。
public struct InputCalibrationColorMeasurement: Codable, Equatable, Sendable {
    public let domain: ValidationDomain
    public let maximumAbsoluteError: Double
    public let sampleCount: Int
}
/// 依据冻结的颜色阈值与实拍验收数据验证输入校准资格。
public struct CalibrationQualificationValidator {
    public static let metric = "encodedRGBMaximumAbsoluteError"
    public static let unit = "normalizedEncodedRGB"
    private let loader: any InputCalibrationPairLoading
    public init(loader: any InputCalibrationPairLoading) { self.loader = loader }
    /// 对验收集使用校准后的输入和独立工作参考。通过后将资格绑定到校准、项目、文件、条件及执行配置。
    public func validate(_ calibration: InputCalibration, dataset: CalibrationDataset, policy: ValidationPolicy) async throws -> CalibrationQualification {
        let threshold = try Self.colorThreshold(policy, frozen: dataset.project.validationPolicy)
        guard dataset.project.authorizationSource?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw LabError.measurement("Real input/reference provenance is required for qualification")
        }
        let loaded = try await loader.load(dataset, split: .acceptance, calibration: calibration, maxSamples: 100_000)
        try Self.validateIdentity(calibration, source: dataset.project.source, effectiveRecipe: loaded.effectiveRecipe, reference: dataset.project.working, referenceDigest: loaded.referenceIdentity)
        guard loaded.measuredFiles, !loaded.fileDigests.isEmpty, !loaded.referenceIdentity.isEmpty, let execution = loaded.execution else {
            throw LabError.measurement("Development data cannot confer measured input qualification")
        }
        guard let axes = dataset.project.inputQualificationAxes, !axes.isEmpty,
              Set(axes).count == axes.count, Set(loaded.conditionRanges.map(\.axis)) == Set(axes) else {
            throw LabError.measurement("Measured qualification does not cover exactly the frozen input axes")
        }
        let measurement = try Self.measure(loaded.pairs)
        guard measurement.maximumAbsoluteError <= threshold else { throw LabError.measurement("Independent input color residual exceeds the frozen project threshold") }
        struct Evidence: Encodable {
            let algorithm: String
            let calibration: String
            let project: String
            let reference: String
            let files: [String]
            let policy: ValidationPolicy
            let measurement: InputCalibrationColorMeasurement
            let conditions: [ConditionRange]
            let execution: ExecutionProfile
        }
        let evidence = Evidence(algorithm: "input-color-validation-v1", calibration: try calibration.processingDigest(),
                                project: dataset.report.projectDigest, reference: loaded.referenceIdentity,
                                files: loaded.fileDigests, policy: policy, measurement: measurement, conditions: loaded.conditionRanges, execution: execution)
        return CalibrationQualification(domain: .colorTone, evidenceDigest: Digest.data(try JSON.encode(evidence)), conditionRanges: loaded.conditionRanges)
    }
    /// 核验校准所声明的源、有效配方、工作空间与参考摘要。
    public static func validateIdentity(_ calibration: InputCalibration, source: SourceDescriptor,
                                        effectiveRecipe: EffectiveInputRecipe, reference: WorkingImageContract, referenceDigest: String? = nil) throws {
        try calibration.validate()
        guard calibration.source == source, calibration.recipeDigest == (try effectiveRecipe.digest()), calibration.working == reference, calibration.referenceDigest == referenceDigest else {
            throw LabError.invalid("Calibration evidence belongs to a different source path, effective recipe or reference")
        }
    }
    /// 读取唯一且单位匹配的颜色上限。提供冻结策略时，要求策略内容完全一致。
    public static func colorThreshold(_ policy: ValidationPolicy, frozen: ValidationPolicy? = nil) throws -> Double {
        try policy.validate()
        if let frozen, frozen != policy { throw LabError.measurement("Validation policy differs from the frozen project policy") }
        let color = policy.thresholds.filter { $0.domain == .colorTone }
        guard color.count == 1, color[0].metric == metric, color[0].unit == unit else {
            throw LabError.measurement("An explicit supported color threshold is required; no default measured gate")
        }
        return color[0].maximum
    }
    /// 跨所有颜色对与通道求编码 RGB 最大绝对误差。
    public static func measure(_ pairs: [InputCalibrationPair]) throws -> InputCalibrationColorMeasurement {
        guard !pairs.isEmpty else { throw LabError.measurement("Missing independent input/reference measurements") }
        var worst = 0.0
        for pair in pairs {
            try pair.validate()
            for (input, reference) in zip(pair.input, pair.reference) { worst = max(worst, abs(input - reference)) }
        }
        return .init(domain: .colorTone, maximumAbsoluteError: worst, sampleCount: pairs.count)
    }
}
