import Foundation
import ImagingCore

/// 逐域记录验证状态、证据类型、指标及参与比较的样本。
public struct ModelDomainValidation: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case passed, failed, insufficient }
    public enum Evidence: String, Codable, Sendable { case development, capturedTarget }
    public let domain: ValidationDomain
    public let status: Status
    public let evidence: Evidence
    public let measurements: [String: Double]
    public let sampleIDs: [String]
    public let reasons: [String]
    // Results are produced by validators, not a user-supplied passed argument.
    init(domain: ValidationDomain, status: Status, evidence: Evidence = .development,
         measurements: [String: Double] = [:], sampleIDs: [String] = [], reasons: [String]) {
        self.domain = domain; self.status = status; self.evidence = evidence
        self.measurements = measurements; self.sampleIDs = sampleIDs; self.reasons = reasons
    }
}
/// 绑定模型包、项目、策略、解码与执行配置的逐域验证报告。
public struct ModelValidationReport: Codable, Equatable, Sendable {
    public let version: Int
    public let packageDigest: String
    public let modelDigest: String
    public let projectDigest: String
    public let policyDigest: String
    public let execution: ExecutionProfile
    /// Rendering allowance within the requested budget; file/target/readback work uses the reserved remainder.
    public let measurementExecution: ExecutionProfile
    public let source: SourceDescriptor
    public let targetSource: SourceDescriptor
    public let targetRecipeDigest: String
    public let algorithmVersions: [String: String]
    public let targetDecodingDigest: String?
    public let effectiveSourceIDs: [String]
    public let domains: [ModelDomainValidation]
    /// 仅列出使用实拍目标证据且通过阈值的域。
    public var measuredDomains: [ValidationDomain] {
        domains.filter { $0.status == .passed && $0.evidence == .capturedTarget }.map(\.domain)
    }
    /// 复核报告所绑定的输入、模型、策略、精度和执行配置，并重新检查原始文件。摘要用于内容核对。
    public func validateBinding(package: StyleModelPackage, dataset: CalibrationDataset, policy: ValidationPolicy,
                                execution: ExecutionProfile, targetSource: SourceDescriptor, targetRecipe: InputRecipe) throws {
        _ = try package.load()
        try targetSource.validate()
        guard source == package.manifest.source, self.targetSource == targetSource,
              targetSource.recipeID == targetRecipe.id, targetRecipeDigest == (try targetRecipe.digest()) else {
            throw LabError.invalid("Validation input source or target decoding declaration changed")
        }
        try measurementExecution.validate()
        let effects = try execution.effectResolutions(), measuredEffects = try measurementExecution.effectResolutions()
        guard measurementExecution.precision == execution.precision,
              measurementExecution.dynamicRange == execution.dynamicRange,
              measurementExecution.width == execution.width, measurementExecution.height == execution.height,
              measuredEffects == effects, measurementExecution.previewGlow == execution.previewGlow,
              measurementExecution.statisticsLatency == execution.statisticsLatency,
              measurementExecution.budget.maxResidentBytes <= execution.budget.maxResidentBytes,
              measurementExecution.budget.maxInFlightFrames <= execution.budget.maxInFlightFrames else {
            throw LabError.invalid("Measurement execution differs from the validated delivery contract")
        }
        guard version == 1, packageDigest == (try package.digest()), modelDigest == package.manifest.modelDigest,
              projectDigest == dataset.report.projectDigest, policy == dataset.project.validationPolicy,
              policyDigest == Digest.data(try JSON.encode(policy)), self.execution == execution,
              Set(domains.map(\.domain)) == Set(ValidationDomain.allCases), domains.count == ValidationDomain.allCases.count else {
            throw LabError.invalid("Validation report belongs to different content, policy or execution")
        }
        // Recheck bytes even when metadata has not changed.
        _ = try DatasetValidator(baseDirectory: dataset.baseDirectory).validate(dataset.project)
    }
}
/// 宿主设备原始交付观测。耗时以秒计，峰值驻留内存以字节计。
public struct DeliveryMeasurements: Codable, Equatable, Sendable {
    public let device: String, operatingSystem: String
    public let durationSeconds: Double
    public let deliveredFrames: Int, droppedFrames: Int, maximumInFlightFrames: Int, peakResidentBytes: Int
    public let endToEndP95Seconds: Double
    public let stageCPUSeconds: [String: [Double]]
    public let stageGPUSeconds: [String: [Double]]
    public let thermalNotes: String
    public init(device: String, operatingSystem: String, durationSeconds: Double, deliveredFrames: Int, droppedFrames: Int,
                maximumInFlightFrames: Int, peakResidentBytes: Int, endToEndP95Seconds: Double,
                stageCPUSeconds: [String: [Double]], stageGPUSeconds: [String: [Double]], thermalNotes: String) {
        self.device = device; self.operatingSystem = operatingSystem; self.durationSeconds = durationSeconds
        self.deliveredFrames = deliveredFrames; self.droppedFrames = droppedFrames; self.maximumInFlightFrames = maximumInFlightFrames
        self.peakResidentBytes = peakResidentBytes; self.endToEndP95Seconds = endToEndP95Seconds
        self.stageCPUSeconds = stageCPUSeconds; self.stageGPUSeconds = stageGPUSeconds; self.thermalNotes = thermalNotes
    }
}
/// 将独立模型验证报告与指定交付规格及设备性能证据关联。
public struct AcceptanceRun: Codable, Equatable, Sendable {
    public let specification: DeliverySpecification
    public let validationReportDigest: String
    public let measurements: DeliveryMeasurements?
    public let performance: ModelDomainValidation
    public let missingRequirements: [String]
    /// 按规格核对宿主、逐阶段耗时、吞吐及资源限制，并记录缺失的验收证据。
    public static func evaluate(specification: DeliverySpecification, report: ModelValidationReport, measurements: DeliveryMeasurements?) throws -> Self {
        try specification.validate()
        guard specification.execution == report.execution, specification.inputPath == report.source.path else { throw LabError.invalid("Delivery execution differs from validation") }
        var missing = [String]()
        if !report.measuredDomains.contains(.colorTone) { missing.append("Independent captured target color/tone validation is missing") }
        for domain in report.domains where domain.domain != .performance && domain.status != .passed {
            missing.append("Required \(domain.domain.rawValue) validation is \(domain.status.rawValue)")
        }
        let result: ModelDomainValidation
        if let m = measurements {
            let requiredCPU = Set(["input", "statistics", "evaluation", "effects", "output"])
            let requiredGPU = Set(["input", "statistics", "effects", "output"])
            let times = Array(m.stageCPUSeconds.values).flatMap { $0 } + Array(m.stageGPUSeconds.values).flatMap { $0 }
            guard m.device == specification.device, m.operatingSystem == specification.operatingSystem,
                  m.durationSeconds.isFinite, m.durationSeconds > 0, m.deliveredFrames > 0, m.droppedFrames >= 0,
                  m.maximumInFlightFrames > 0, m.peakResidentBytes > 0,
                  m.endToEndP95Seconds.isFinite, m.endToEndP95Seconds >= 0,
                  times.allSatisfy({ $0.isFinite && $0 >= 0 }) else { throw LabError.invalid("Invalid or mismatched host delivery measurements") }
            let complete = requiredCPU.isSubset(of: Set(m.stageCPUSeconds.filter {  $0.value.count >= m.deliveredFrames }.keys)) &&
                requiredGPU.isSubset(of: Set(m.stageGPUSeconds.filter {  $0.value.count >= m.deliveredFrames }.keys)) && !m.thermalNotes.isEmpty
            let total = Double(m.deliveredFrames) + Double(m.droppedFrames)
            let drop = Double(m.droppedFrames) / total
            let enough = m.durationSeconds >= specification.sustainedDurationSeconds
            let throughput: Bool
            if case .video(let fps) = specification.medium {
                throughput = Double(m.deliveredFrames) / m.durationSeconds >= fps * (1 - specification.maximumDroppedFrameFraction)
            } else { throughput = true }
            let pass = enough && throughput && m.endToEndP95Seconds <= specification.maxLatencySeconds &&
                m.maximumInFlightFrames <= specification.execution.budget.maxInFlightFrames &&
                m.peakResidentBytes <= specification.execution.budget.maxResidentBytes && drop <= specification.maximumDroppedFrameFraction
            var reasons = [String]()
            if !complete { reasons.append("Missing per-stage timing or thermal observations") }
            if !enough { reasons.append("Sustained measurement duration is insufficient") }
            if !throughput { reasons.append("Delivered frame rate is below the declared sustained target") }
            if !pass { reasons.append("One or more delivery limits were not met") }
            result = .init(domain: .performance, status: !complete || !enough ? .insufficient : (pass ? .passed : .failed),
                measurements: ["endToEndP95Seconds": m.endToEndP95Seconds, "droppedFrameFraction": drop,
                               "peakResidentBytes": Double(m.peakResidentBytes), "durationSeconds": m.durationSeconds], reasons: reasons)
        } else {
            missing.append("Declared device delivery measurements are missing")
            result = .init(domain: .performance, status: .insufficient, reasons: ["No host measurement"])
        }
        return .init(specification: specification, validationReportDigest: Digest.data(try JSON.encode(report)),
            measurements: measurements, performance: result, missingRequirements: missing)
    }
}
