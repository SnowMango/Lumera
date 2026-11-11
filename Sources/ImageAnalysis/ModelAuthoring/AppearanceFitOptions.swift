import Foundation
import ImagingCore

/// 全局颜色外观拟合预算。残差 LUT 的触发阈值使用归一化编码 RGB 的最大通道误差。
public struct AppearanceFitOptions: Codable, Equatable, Sendable {
    public var regularization: Double
    public var maxIterations: Int
    public var convergenceTolerance: Double
    public var seed: UInt64
    public var maximumSamples: Int
    public var grayWeight: Double
    public var residualEnabled: Bool
    public var residualDimension: Int
    public var residualTrigger: Double
    public init(regularization: Double = 1e-3, maxIterations: Int = 100, convergenceTolerance: Double = 1e-6,
                seed: UInt64 = 0, maximumSamples: Int = 20_000, grayWeight: Double = 4,
                residualEnabled: Bool = true, residualDimension: Int = 17, residualTrigger: Double = 0.005) {
        self.regularization = regularization; self.maxIterations = maxIterations; self.convergenceTolerance = convergenceTolerance
        self.seed = seed; self.maximumSamples = maximumSamples; self.grayWeight = grayWeight
        self.residualEnabled = residualEnabled; self.residualDimension = residualDimension; self.residualTrigger = residualTrigger
    }
    public func validate() throws {
        guard regularization.isFinite, regularization >= 0, regularization <= 1e6, (1...1000).contains(maxIterations),
              convergenceTolerance.isFinite, convergenceTolerance > 0, convergenceTolerance < 1,
              (3...100_000).contains(maximumSamples), grayWeight.isFinite, (1...100).contains(grayWeight),
              [17,33].contains(residualDimension), residualTrigger.isFinite, residualTrigger >= 0, residualTrigger <= 1 else {
            throw LabError.invalid("Invalid bounded appearance fit options")
        }
    }
}
