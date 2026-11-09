import Foundation

/// 按参数注册表中的目标 ID 提供一个完整控制值。
public struct ControlOverride: Codable, Equatable, Sendable {
    public var target: String
    public var value: ControlValue
    public init(target: String, value: ControlValue) { self.target = target; self.value = value }
}
/// 视觉控制的偏移量，单位与对应 `VisualControl` 一致。
public struct VisualOffset: Codable, Equatable, Sendable {
    public var id: String
    public var value: Double
    public init(id: String, value: Double) { self.id = id; self.value = value }
}
/// 将同一视觉滑杆的偏移按系数映射到一个或多个标量参数。零表示无偏移。
public struct VisualControl: Codable, Equatable, Sendable {
    public struct Link: Codable, Equatable, Sendable {
        public var target: String
        public var coefficient: Double
        public init(target: String, coefficient: Double) { self.target = target; self.coefficient = coefficient }
    }
    public var id: String
    public var unit: ParameterUnit
    public var bounds: NumericBounds
    public var links: [Link]
    public init(id: String, unit: ParameterUnit, bounds: NumericBounds, links: [Link]) {
        self.id = id; self.unit = unit; self.bounds = bounds; self.links = links
    }
}
/// 整体强度为零时的中性端点；强度为一时使用自动控制。
public struct StrengthDefinition: Codable, Equatable, Sendable {
    public var neutralParameters: StyleParameters
    public var neutralLUTWeights: [ResourceWeight]
    public init(neutralParameters: StyleParameters, neutralLUTWeights: [ResourceWeight] = []) {
        self.neutralParameters = neutralParameters; self.neutralLUTWeights = neutralLUTWeights
    }
}
/// 声明允许的输入修正、视觉偏移、显式覆盖和整体强度。
public struct EditCapabilities: Codable, Equatable, Sendable {
    public var allowsInputExposure = true
    public var allowsInputWhiteBalance = true
    public var visualControls: [VisualControl] = []
    /// 同时用于限制显式覆盖和锁定的目标集合。
    public var overrideTargets: [String] = []
    public var strength: StrengthDefinition?
    public init() {}
    public func validate() throws {
        guard Set(visualControls.map(\.id)).count == visualControls.count, Set(overrideTargets).count == overrideTargets.count else {
            throw LabError.invalid("Duplicate edit capability")
        }
        for control in visualControls {
            try control.bounds.validate()
            guard !control.id.isEmpty, control.bounds.contains(0), !control.links.isEmpty,
                  Set(control.links.map(\.target)).count == control.links.count else { throw LabError.invalid("Invalid visual control") }
            for link in control.links {
                let spec = try ParameterSpecification.lookup(link.target)
                guard spec.editable, spec.shape == .scalar, link.coefficient.isFinite else { throw LabError.invalid("Invalid visual control link") }
            }
        }
        for target in overrideTargets {
            guard try ParameterSpecification.lookup(target).editable else { throw LabError.invalid("Parameter is not editable") }
        }
        if let strength { try strength.neutralParameters.validate(); try ResourceWeight.validate(strength.neutralLUTWeights) }
    }
}
/// 一帧的临时编辑请求。默认没有输入修正、视觉偏移、覆盖、锁定或强度混合。
public struct EditRequest: Codable, Equatable, Sendable {
    /// 输入阶段的曝光修正，单位为 EV。
    public var inputExposureEV = 0.0
    public var inputWhiteBalance: WhiteBalanceCorrection?
    public var visualOffsets: [VisualOffset] = []
    public var overrides: [ControlOverride] = []
    public var locks: [ControlOverride] = []
    /// 0 为中性端点，1 为自动控制；省略则跳过强度混合。
    public var strength: Double?
    public init() {}
}
/// 供渲染使用的最终控制，保留自动控制以追溯编辑前的决策。
public struct ResolvedControls: Codable, Equatable, Sendable {
    public var automatic: AutomaticControls
    public var parameters: StyleParameters
    public var lutWeights: [ResourceWeight]
    public var inputExposureEV: Double
    public var inputWhiteBalance: WhiteBalanceCorrection?
    public var lockedTargets: [String]
    public var diagnostics: [ControlDiagnostic]
    public init(automatic: AutomaticControls, parameters: StyleParameters, lutWeights: [ResourceWeight], inputExposureEV: Double = 0, inputWhiteBalance: WhiteBalanceCorrection? = nil, lockedTargets: [String] = [], diagnostics: [ControlDiagnostic] = []) {
        self.automatic = automatic; self.parameters = parameters; self.lutWeights = lutWeights
        self.inputExposureEV = inputExposureEV; self.inputWhiteBalance = inputWhiteBalance
        self.lockedTargets = lockedTargets; self.diagnostics = diagnostics
    }
}
public enum AdaptationResetReason: String, Codable, Sendable { case sceneCut, seek, sourceChanged, modelChanged, gpuFailure }
/// 对调用方持有的时间历史应用一次状态事件。
public enum AdaptationEvent: Codable, Equatable, Sendable {
    case reset(AdaptationResetReason)
    case lock([ControlOverride])
    /// 解锁需提供已存储的锁值。解锁帧保持该值，后续帧恢复适应。
    case unlock([ControlOverride])
}
/// 为单个控制指定首帧、平滑、死区以及观测过期后的处理。
public struct AdaptationRule: Codable, Equatable, Sendable {
    public enum Initialization: Codable, Equatable, Sendable { case immediate, constant(ControlValue) }
    public var target: String
    /// 指数平滑时间常数，单位为秒；0 表示直接跟随目标，仍可应用死区。
    public var timeConstantSeconds: Double
    public var hysteresis = 0.0
    public var initialization: Initialization = .immediate
    /// 从最近有效观测起算的允许缺测秒数；从未有效时从首次缺测帧起算。
    public var maximumMissingSeconds = 0.0
    public var expired: MissingObservationPolicy = .reject
    public init(target: String, timeConstantSeconds: Double) { self.target = target; self.timeConstantSeconds = timeConstantSeconds }
}
/// 每个目标只允许一条时间规则；未配置的控制不参与时间平滑。
public struct AdaptationPolicy: Codable, Equatable, Sendable {
    public var rules: [AdaptationRule] = []
    public init() {}
    public func validate() throws {
        try ParameterSpecification.validateOwners(rules.map(\.target))
        for rule in rules {
            let spec = try ParameterSpecification.lookup(rule.target)
            guard [rule.timeConstantSeconds, rule.hysteresis, rule.maximumMissingSeconds].allSatisfy({ $0.isFinite && $0 >= 0 }) else {
                throw LabError.invalid("Invalid adaptation timing")
            }
            if case .constant(let value) = rule.initialization { try spec.validate(value) }
            switch rule.expired {
            case .reject: break
            case .constant(let value): try spec.validate(value)
            case .hold: throw LabError.invalid("Expired observations cannot extend their own hold")
            }
        }
    }
}
