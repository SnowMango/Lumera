import Foundation
import ImagingCore

/// 离线拟合的迭代、样本和复杂度预算，以及求解器支持的固定参数。验收阈值由项目策略单独声明。
public struct FitOptions: Codable, Equatable, Sendable {
    public let maxIterations: Int
    public let maxSamples: Int
    public let maxComplexity: Int
    public let convergenceTolerance: Double
    public let fixedParameters: [String]
    public let seed: UInt64
    public init(maxIterations: Int = 100, maxSamples: Int = 100_000, maxComplexity: Int = 33,
                convergenceTolerance: Double = 1e-6, fixedParameters: [String] = [], seed: UInt64 = 0) {
        self.maxIterations = maxIterations; self.maxSamples = maxSamples; self.maxComplexity = maxComplexity
        self.convergenceTolerance = convergenceTolerance; self.fixedParameters = fixedParameters; self.seed = seed
    }
    public func validate() throws {
        guard maxIterations > 0, maxSamples > 0, maxComplexity > 0,
              convergenceTolerance.isFinite, convergenceTolerance > 0,
              Set(fixedParameters).count == fixedParameters.count,
              fixedParameters.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw LabError.invalid("Invalid fit budgets or fixed parameters")
        }
        for parameter in fixedParameters { _ = try ParameterSpecification.lookup(parameter) }
    }
}
public enum ValidationDomain: String, Codable, CaseIterable, Sendable {
    case colorTone, texture, condition, temporal, precision, performance
}
/// 项目显式声明的指标上限，带适用域与单位。
public struct ValidationThreshold: Codable, Equatable, Sendable {
    public let domain: ValidationDomain
    public let metric: String
    public let unit: String
    public let maximum: Double
    public init(domain: ValidationDomain, metric: String, unit: String, maximum: Double) {
        self.domain = domain; self.metric = metric; self.unit = unit; self.maximum = maximum
    }
}
/// 冻结验收使用的策略版本和各域指标阈值。
public struct ValidationPolicy: Codable, Equatable, Sendable {
    public let version: String
    public let thresholds: [ValidationThreshold]
    public init(version: String = "1", thresholds: [ValidationThreshold] = []) {
        self.version = version; self.thresholds = thresholds
    }
    public func validate() throws {
        guard !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LabError.invalid("Missing validation policy version") }
        var keys = Set<String>()
        for threshold in thresholds {
            guard !threshold.metric.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !threshold.unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  threshold.maximum.isFinite, threshold.maximum >= 0,
                  keys.insert(threshold.domain.rawValue + ":" + threshold.metric).inserted else {
                throw LabError.invalid("Invalid or duplicate project validation threshold")
            }
        }
    }
}
