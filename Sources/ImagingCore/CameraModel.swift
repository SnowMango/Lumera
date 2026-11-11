import Foundation

/// 标识拟复现的相机、模式及其可选固件和设置。输入设备由 `SourceDescriptor` 独立描述。
public struct TargetIdentity: Codable, Equatable, Sendable {
    public var id: String, camera: String, mode: String
    public var firmware: String?
    public var settings: [String: String] = [:]
    public init(id: String, camera: String, mode: String) { self.id = id; self.camera = camera; self.mode = mode }
}
/// 声明资源的内容摘要和采样契约。加载层据此校验实际资源；模型只保存描述。
public struct ModelResourceDescriptor: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable { case styleLUT, correctionLUT, toneCurve }
    public enum ColorDomain: String, Codable, Sendable { case encodedSRGB, linearSRGB }
    public enum OutOfRange: String, Codable, Sendable { case clamp, linearExtrapolation, reject }
    public var id: String, sha256: String
    public var version = 1
    public var role: Role = .styleLUT
    /// 默认按编码 sRGB 取样并输出编码 sRGB；线性资源须明确声明其域。
    public var inputDomain: ColorDomain = .encodedSRGB
    public var outputDomain: ColorDomain = .encodedSRGB
    public var inputBounds = NumericBounds(lower: 0, upper: 1)
    public var outputBounds = NumericBounds(lower: 0, upper: 1)
    /// 三维 LUT 每轴的采样数，或色调曲线的一维采样数。
    public var dimension: Int
    public var channels = 3
    public var outOfRange: OutOfRange = .clamp
    public init(id: String, sha256: String, dimension: Int) { self.id = id; self.sha256 = sha256; self.dimension = dimension }
    public func validate() throws {
        guard !id.isEmpty, version == 1, (2...256).contains(dimension), channels == (role == .toneCurve ? 1 : 3) else {
            throw LabError.invalid("Invalid model resource descriptor")
        }
        try validateDigest(sha256); try inputBounds.validate(); try outputBounds.validate()
        guard inputBounds.upper > inputBounds.lower else { throw LabError.invalid("Resource input range must be nonempty") }
    }
    public static func validate(_ values: [Self]) throws {
        guard Set(values.map(\.id)).count == values.count else { throw LabError.invalid("Duplicate model resource ID") }
        for value in values { try value.validate() }
    }
}
/// 自动响应求值的起点，包括基础风格参数和 LUT 权重。
public struct AppearanceDefinition: Codable, Equatable, Sendable {
    public var parameters = StyleParameters()
    /// 噪点与颗粒的渲染时序策略。响应控制的跨帧适应由模型的 `adaptation` 定义。
    public var temporalPolicy = TemporalPolicy()
    public var resources: [ModelResourceDescriptor] = []
    public var lutWeights: [ResourceWeight] = []
    public init() {}
}
/// 声明模型所需的参考呈现、动态范围、输入资质及目标条件。
public struct ModelCompatibility: Codable, Equatable, Sendable {
    public var referenceRenditionIDs: [String] = []
    public var dynamicRanges: [ModelDynamicRange] = [.sdr]
    public var requiredQualifications: [CalibrationQualification.Domain] = []
    public var requiredCapabilities: [String] = []
    public var targetConditions: [ConditionRange] = []
    public init() {}
}
/// Evidence references do not by themselves confer measured qualification.
public struct CoverageManifest: Codable, Equatable, Sendable {
    public var evidenceDigests: [String] = []
    public var conditions: [ConditionRange] = []
    public init() {}
}
/// 可序列化的相机外观定义。将外观、观测依赖、自动响应、时间适应和用户编辑权限作为独立声明。
public struct CameraModel: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    /// 参数注册表和响应表达式的语义各自版本化，以便读取时拒绝未知语义。
    public var parameterSemanticsVersion = 1
    public var responseSemanticsVersion = 1
    public var identity: TargetIdentity
    public var appearance = AppearanceDefinition()
    public var observations = ObservationRequirements()
    public var responses: [ResponseProgram] = []
    public var adaptation = AdaptationPolicy()
    public var edits = EditCapabilities()
    public var compatibility = ModelCompatibility()
    public var coverage = CoverageManifest()
    /// An explicit schema-8 bridge, interpreted only by LegacyProfileAdapter/evaluator.
    public var legacyProfile: Profile?
    public init(identity: TargetIdentity) { self.identity = identity }
    public func validate() throws {
        guard schemaVersion == 1, parameterSemanticsVersion == 1, responseSemanticsVersion == 1,
              !identity.id.isEmpty, !identity.camera.isEmpty, !identity.mode.isEmpty else {
            throw LabError.invalid("Unsupported camera model version or missing identity")
        }
        try appearance.parameters.validate(); try ModelResourceDescriptor.validate(appearance.resources)
        try observations.validate(); try edits.validate(); try adaptation.validate()
        try ConditionRange.validate(compatibility.targetConditions); try ConditionRange.validate(coverage.conditions)
        guard !compatibility.dynamicRanges.isEmpty, Set(compatibility.dynamicRanges).count == compatibility.dynamicRanges.count,
              Set(compatibility.referenceRenditionIDs).count == compatibility.referenceRenditionIDs.count,
              compatibility.referenceRenditionIDs.allSatisfy({ !$0.isEmpty }) else { throw LabError.invalid("Invalid model compatibility") }
        for digest in coverage.evidenceDigests { try validateDigest(digest) }
        try ParameterSpecification.validateOwners(responses.map(\.target))
        let featureIDs = Set(observations.features.map(\.id))
        func validateResources(_ weights: [ResourceWeight]) throws {
            try ResourceWeight.validate(weights)
            for weight in weights {
                guard appearance.resources.contains(where: { $0.id == weight.resourceID && $0.role == .styleLUT }) else {
                    throw LabError.invalid("Unresolved style LUT: \(weight.resourceID)")
                }
            }
        }
        try validateResources(appearance.lutWeights)
        if let strength = edits.strength { try validateResources(strength.neutralLUTWeights) }
        for rule in adaptation.rules {
            if case .constant(.resourceWeights(let weights)) = rule.expired { try validateResources(weights) }
            if case .constant(.resourceWeights(let weights)) = rule.initialization { try validateResources(weights) }
        }
        for response in responses {
            try response.validate()
            for axis in response.expression.axes {
                if case .feature(let id) = axis, !featureIDs.contains(id) { throw LabError.invalid("Undeclared feature: \(id)") }
                if case .source(let a) = axis, !observations.sourceConditions.contains(a) { throw LabError.invalid("Undeclared source condition") }
            }
            var values = response.expression.values
            if case .constant(let value) = response.missing { values.append(value) }
            for value in values { if case .resourceWeights(let weights) = value { try validateResources(weights) } }
        }
        if let legacyProfile {
            try legacyProfile.validate()
            guard responses.isEmpty, legacyProfile.parameters == appearance.parameters else { throw LabError.invalid("Legacy and new response owners cannot be mixed") }
        }
        // Apply the persisted structure budget to every array, including nested control values.
        // Use raw encoding here: calling CameraModelCodec.encode would recurse into validate().
        try CameraModelCodec.validateStructure(JSON.encode(self))
    }
    /// 验证后计算完整模型定义的内容摘要，用于区分同一展示 ID 下的模型修订。
    public func digest() throws -> String { try validate(); return try StyleIdentity.digest(self) }
}
