import Foundation

/// 工作缓冲的 RGBA 浮点存储精度，默认每通道 16 位。渲染着色器仍以 32 位浮点计算。
public enum ExecutionPrecision: String, Codable, Sendable {
    case float16, float32
    public static let `default`: Self = .float16
    public var bytesPerPixel: Int { self == .float16 ? 8 : 16 }
}
/// 调用方声明的同时在途帧数和驻留字节上限。
public struct ExecutionBudget: Codable, Equatable, Sendable {
    public var maxInFlightFrames: Int
    public var maxResidentBytes: Int
    public init(maxInFlightFrames: Int, maxResidentBytes: Int) { self.maxInFlightFrames = maxInFlightFrames; self.maxResidentBytes = maxResidentBytes }
    public func validate() throws {
        guard maxInFlightFrames > 0, maxResidentBytes > 0 else { throw LabError.invalid("Execution budgets must be positive and explicit") }
    }
}
/// 执行计划的统计延迟模式；延迟模式同时受帧数和秒数约束。
public enum StatisticsLatency: Codable, Equatable, Sendable {
    case sameFrame
    case delayed(maxFrames: UInt64, maxSeconds: Double)
}
/// 声明输出像素尺寸、存储精度、效果分辨率比例与资源预算。
public struct ExecutionProfile: Codable, Equatable, Sendable {
    public var precision: ExecutionPrecision = .default
    public var width: Int, height: Int
    public var dynamicRange: ModelDynamicRange = .sdr
    public var effectScale = 1.0
    public var statisticsLatency: StatisticsLatency = .sameFrame
    public var budget: ExecutionBudget
    public init(width: Int, height: Int, budget: ExecutionBudget) { self.width = width; self.height = height; self.budget = budget }
    public func validate() throws {
        _ = try ImageDimensions.pixelCount(width: width, height: height)
        try budget.validate()
        guard effectScale.isFinite, effectScale > 0 else { throw LabError.invalid("Invalid effect scale") }
        if case .delayed(let frames, let seconds) = statisticsLatency {
            guard frames > 0, seconds.isFinite, seconds > 0 else { throw LabError.invalid("Delayed observation age must be bounded") }
        }
    }
}
/// Frozen final decision. Automatic replay uses DecisionRecord instead.
public struct FrameDecision: Codable, Equatable, Sendable {
    public var version = 1
    public var stamp: FrameStamp
    public var modelDigest: String, inputDigest: String, resourceDigest: String
    public var observations: FrameObservations
    public var edits: EditRequest
    public var controls: ResolvedControls
    public var seed: UInt32
    public var sourceFrameIndex: UInt64
    public init(stamp: FrameStamp, modelDigest: String, inputDigest: String, resourceDigest: String, observations: FrameObservations, edits: EditRequest, controls: ResolvedControls, seed: UInt32) {
        self.stamp = stamp; self.modelDigest = modelDigest; self.inputDigest = inputDigest; self.resourceDigest = resourceDigest
        self.observations = observations; self.edits = edits; self.controls = controls; self.seed = seed; self.sourceFrameIndex = stamp.index
    }
}

/// A host's declared delivery target. Library engineering tests do not fill missing product requirements.
public struct DeliverySpecification: Codable, Equatable, Sendable {
    public enum Medium: Codable, Equatable, Sendable { case photo; case video(framesPerSecond: Double) }
    public let device: String
    public let operatingSystem: String
    public let inputPath: SourceDescriptor.Path
    public let medium: Medium
    public let execution: ExecutionProfile
    /// 宿主验证的端到端第 95 百分位延迟上限，单位为秒。
    public let maxLatencySeconds: Double
    /// 宿主验证要求的最短持续测量时间，单位为秒。
    public let sustainedDurationSeconds: Double
    /// 允许丢帧占交付与丢弃帧总数的比例，取值为 0...1。
    public let maximumDroppedFrameFraction: Double
    public init(device: String, operatingSystem: String, inputPath: SourceDescriptor.Path, medium: Medium,
                execution: ExecutionProfile, maxLatencySeconds: Double, sustainedDurationSeconds: Double,
                maximumDroppedFrameFraction: Double) {
        self.device = device; self.operatingSystem = operatingSystem; self.inputPath = inputPath; self.medium = medium
        self.execution = execution; self.maxLatencySeconds = maxLatencySeconds; self.sustainedDurationSeconds = sustainedDurationSeconds
        self.maximumDroppedFrameFraction = maximumDroppedFrameFraction
    }
    public func validate() throws {
        try execution.validate()
        guard !device.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !operatingSystem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, inputPath != .unknown,
              maxLatencySeconds.isFinite, maxLatencySeconds > 0,
              sustainedDurationSeconds.isFinite, sustainedDurationSeconds > 0,
              maximumDroppedFrameFraction.isFinite, (0...1).contains(maximumDroppedFrameFraction) else {
            throw LabError.invalid("Delivery requires explicit device, timing, memory and drop budgets")
        }
        if case .video(let fps) = medium {
            guard fps.isFinite, fps > 0 else { throw LabError.invalid("Video delivery requires a positive frame rate") }
        }
    }
}
