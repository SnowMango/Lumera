import Foundation

/// 源流帧的身份和媒体时间。
public struct FrameStamp: Codable, Equatable, Sendable {
    public var streamID: String
    /// 流世代与源帧索引。时序历史只在同一流和同一世代内延续。
    public var generation: UInt64, index: UInt64
    /// 呈现时间及帧时长，均以秒为单位。
    public var presentationTime: Double, duration: Double
    public init(streamID: String, generation: UInt64, index: UInt64, presentationTime: Double, duration: Double) {
        self.streamID = streamID; self.generation = generation; self.index = index
        self.presentationTime = presentationTime; self.duration = duration
    }
    public func validate() throws {
        guard !streamID.isEmpty, presentationTime.isFinite, duration.isFinite, duration > 0 else { throw LabError.invalid("Invalid frame stamp") }
    }
}
/// 全帧线性 sRGB 像素统计的版本化规格。均值与阈值统计使用未经 0...1 裁切的样本。
/// 当前渲染器的亮度分位数取 0...1 内 256 档直方图的命中档中心，越界样本计入端点档。
public struct FeatureSpecification: Codable, Equatable, Sendable {
    public enum Statistic: Codable, Equatable, Sendable {
        case luminanceQuantile(Double), fractionBelow(Double), fractionAbove(Double), meanRed, meanGreen, meanBlue
    }
    public var id: String
    public var version = 1
    public var statistic: Statistic
    /// 统计采样长边的像素数。声明允许 16...2048，默认 256；当前渲染器仅接受 256。
    public var samplingLongEdge = 256
    public var domain: ModelResourceDescriptor.ColorDomain = .linearSRGB
    public var fullFrame = true
    public var clipsToUnitRange = false
    public init(id: String, statistic: Statistic) { self.id = id; self.statistic = statistic }
    public func validate() throws {
        guard !id.isEmpty, version == 1, (16...2048).contains(samplingLongEdge), domain == .linearSRGB,
              fullFrame, !clipsToUnitRange else { throw LabError.invalid("Unsupported feature specification") }
        switch statistic {
        case .luminanceQuantile(let p): guard p.isFinite, (0...1).contains(p) else { throw LabError.invalid("Invalid quantile") }
        case .fractionBelow(let t), .fractionAbove(let t): guard t.isFinite else { throw LabError.invalid("Invalid feature threshold") }
        default: break
        }
    }
}
/// Absolute change in axis coordinates: log2 stops for ISO/duration, native units otherwise.
public struct SourceConditionTolerance: Codable, Equatable, Sendable {
    public var axis: ConditionAxis
    public var maxCoordinateDelta: Double
    public init(axis: ConditionAxis, maxCoordinateDelta: Double) { self.axis = axis; self.maxCoordinateDelta = maxCoordinateDelta }
    public static func validate(_ values: [Self]) throws {
        guard Set(values.map(\.axis)).count == values.count,
              values.allSatisfy({ $0.maxCoordinateDelta.isFinite && $0.maxCoordinateDelta >= 0 }) else {
            throw LabError.invalid("Invalid source change tolerance")
        }
    }
}
/// 观测包复用的时间、帧距和采集条件容差。默认只接受当前帧。
public struct ObservationValidityPolicy: Codable, Equatable, Sendable {
    public var maxAgeSeconds = 0.0
    public var maxAgeFrames: UInt64 = 0
    public var sourceChangeTolerances: [SourceConditionTolerance] = []
    public var rejectMissingSourceConditions = true
    public init() {}
    public func validate() throws {
        guard maxAgeSeconds.isFinite, maxAgeSeconds >= 0 else { throw LabError.invalid("Invalid observation age") }
        try SourceConditionTolerance.validate(sourceChangeTolerances)
    }
}
/// 列出自动响应所需的源采集条件和图像特征，并声明观测包何时可复用。
public struct ObservationRequirements: Codable, Equatable, Sendable {
    public var sourceConditions: [ConditionAxis] = []
    public var features: [FeatureSpecification] = []
    public var validity = ObservationValidityPolicy()
    public init() {}
    public func validate() throws {
        guard Set(sourceConditions).count == sourceConditions.count, Set(features.map(\.id)).count == features.count else {
            throw LabError.invalid("Duplicate observation requirement")
        }
        for feature in features { try feature.validate() }; try validity.validate()
    }
    public func featureDigest() throws -> String { try validate(); return try StyleIdentity.digest(features) }
}
/// 以特征规格 ID 记录统计结果；缺测用 nil，可附上原因。
public struct FeatureValue: Codable, Equatable, Sendable {
    public var id: String
    public var value: Double?
    public var invalidReason: String?
    public init(id: String, value: Double?, invalidReason: String? = nil) { self.id = id; self.value = value; self.invalidReason = invalidReason }
}
/// 同一源帧的采集事实与像素统计。延迟使用时仍保留原帧身份。
public struct FrameObservations: Codable, Equatable, Sendable {
    public var stamp: FrameStamp
    /// Content identities, not camera labels: revisions of recipes/calibration invalidate history.
    public var sourceID: String, calibrationID: String, featureDigest: String
    public var captureConditions = CaptureConditions()
    public var features: [FeatureValue] = []
    public init(stamp: FrameStamp, sourceID: String, calibrationID: String, featureDigest: String) {
        self.stamp = stamp; self.sourceID = sourceID; self.calibrationID = calibrationID; self.featureDigest = featureDigest
    }
    public func validate() throws {
        try stamp.validate(); try captureConditions.validate()
        guard !sourceID.isEmpty, !calibrationID.isEmpty, !featureDigest.isEmpty,
              Set(features.map(\.id)).count == features.count,
              features.allSatisfy({ !$0.id.isEmpty && ($0.value?.isFinite ?? true) && !($0.value != nil && $0.invalidReason != nil) }) else {
            throw LabError.invalid("Invalid observation packet")
        }
    }
}
public struct ControlProvenance: Codable, Equatable, Sendable {
    public var target: String
    /// Nil until this control has been evaluated from valid observations.
    public var lastValidStamp: FrameStamp?
    public var isFallback: Bool
    public init(target: String, lastValidStamp: FrameStamp?, isFallback: Bool = false) {
        self.target = target; self.lastValidStamp = lastValidStamp; self.isFallback = isFallback
    }
}
/// Stable codes for replay/UI; explanatory text is not an execution contract.
public struct ControlDiagnostic: Codable, Equatable, Sendable {
    public enum Code: String, Codable, Sendable {
        case missingObservation, legacyApplied, legacyMissingCondition, clamped, overridden
        case constraintAdjusted, strengthApplied, temporalReset, missingExpired
    }
    public var code: Code
    public var target: String?
    public var message: String?
    public init(code: Code, target: String? = nil, message: String? = nil) {
        self.code = code; self.target = target; self.message = message
    }
}
/// 自动阶段的参数与 LUT 权重，附有内容身份、观测来源和诊断。
public struct AutomaticControls: Codable, Equatable, Sendable {
    public var parameters: StyleParameters
    public var lutWeights: [ResourceWeight]
    /// Content digests. A reused display ID cannot authorize old fallback or temporal state.
    public var modelID: String, sourceID: String, calibrationID: String, featureDigest: String
    public var provenance: [ControlProvenance] = []
    public var diagnostics: [ControlDiagnostic] = []
    public init(parameters: StyleParameters, lutWeights: [ResourceWeight] = [], modelID: String, sourceID: String, calibrationID: String, featureDigest: String) {
        self.parameters = parameters; self.lutWeights = lutWeights; self.modelID = modelID
        self.sourceID = sourceID; self.calibrationID = calibrationID; self.featureDigest = featureDigest
    }
}
/// 供后续缺测求值参考的控制快照；每项控制的有效期按各自来源记录判断。
public struct FallbackSnapshot: Codable, Equatable, Sendable {
    public var controls: AutomaticControls
    public var stamp: FrameStamp
    public init(controls: AutomaticControls, stamp: FrameStamp) { self.controls = controls; self.stamp = stamp }
}
/// 将当前求值帧、原始观测包、目标条件与可选回退历史分别传入。
public struct EvaluationContext: Codable, Equatable, Sendable {
    public var evaluationStamp: FrameStamp
    public var observations: FrameObservations
    public var targetConditions: CaptureConditions
    public var fallback: FallbackSnapshot?
    public init(evaluationStamp: FrameStamp, observations: FrameObservations, targetConditions: CaptureConditions = .init(), fallback: FallbackSnapshot? = nil) {
        self.evaluationStamp = evaluationStamp; self.observations = observations; self.targetConditions = targetConditions; self.fallback = fallback
    }
}
/// Facts copied from one immutable prepared input, independent of GPU storage.
public struct FrameInputFacts: Codable, Equatable, Sendable {
    public let stamp: FrameStamp
    public let inputID: String
    public let sourceID: String
    public let calibrationID: String
    public let effectiveRecipeDigest: String
    /// 可选的实际开发配方。存在时须与 `effectiveRecipeDigest` 匹配。
    public let effectiveRecipe: EffectiveInputRecipe?
    public let captureConditions: CaptureConditions
    public init(stamp: FrameStamp, inputID: String, sourceID: String, calibrationID: String, effectiveRecipeDigest: String, captureConditions: CaptureConditions, effectiveRecipe: EffectiveInputRecipe? = nil) {
        self.stamp = stamp; self.inputID = inputID; self.sourceID = sourceID
        self.calibrationID = calibrationID; self.effectiveRecipeDigest = effectiveRecipeDigest
        self.captureConditions = captureConditions; self.effectiveRecipe = effectiveRecipe
    }
    public func validate() throws {
        try stamp.validate(); try captureConditions.validate()
        guard !inputID.isEmpty, !sourceID.isEmpty, !calibrationID.isEmpty else { throw LabError.invalid("Missing prepared input identity") }
        try validateDigest(effectiveRecipeDigest)
        if let effectiveRecipe, try effectiveRecipe.digest() != effectiveRecipeDigest { throw LabError.invalid("Effective recipe facts differ from their digest") }
    }
}
/// Automatic replay inputs, including events and original source timing; not merely a final parameter snapshot.
public struct DecisionRecord: Codable, Equatable, Sendable {
    public var version = 1
    public var modelDigest: String, inputRecipeDigest: String, resourceDigest: String
    public var context: EvaluationContext
    public var event: AdaptationEvent?
    /// 求值帧自身的输入事实，供重放校验。延迟观测仍以自己的原始帧身份保存在 `context` 中。
    public var currentInput: FrameInputFacts?
    public var edits: EditRequest
    public var seed: UInt32
    public init(modelDigest: String, inputRecipeDigest: String, resourceDigest: String, context: EvaluationContext, event: AdaptationEvent? = nil, edits: EditRequest = .init(), seed: UInt32, currentInput: FrameInputFacts? = nil) {
        self.modelDigest = modelDigest; self.inputRecipeDigest = inputRecipeDigest; self.resourceDigest = resourceDigest
        self.context = context; self.event = event; self.edits = edits; self.seed = seed; self.currentInput = currentInput
    }
}
