import Foundation

/// 显式输入检查使用的参数域；域的选择不改变后续执行方式。
public enum ParameterValueDomain: Sendable {
    /// 模型创作和基础参数的声明范围。
    case base
    /// 计算结果的有效范围；不用于扩大基础模型的创作范围。
    case effective
}
/// 变化字段的输入处理策略，不传入渲染流程。
public enum ParameterRangeBehavior: Sendable {
    /// 超出所选范围时拒绝整次更新。
    case reject
    /// 仅限幅有限标量；非有限值及不符合规则的复合值仍然抛错。
    case clamp
}

/// 可选的参数输入处理，供创建、导入或外部编辑时按需调用。
/// 不应在逐帧规划、编码或提交中重复调用；执行流程不要求使用这些入口。
/// 返回值不携带校验状态，后续直接修改公开属性可绕过输入时的保证。
public enum ParameterInput {
    /// 对完整参数执行显式诊断，包含关闭效果的配置，成功时原样返回。
    /// 每次调用都会重新检查；仅修改部分字段时可选择 `update`。
    public static func accept(_ parameters: StyleParameters,
                              domain: ParameterValueDomain = .base) throws -> StyleParameters {
        try parameters.validate(resolved: domain == .effective)
        return parameters
    }

    /// 在副本上处理变化目标及其关联组，全部成功后同时提交参数和权重。
    /// 白点 xy 等关联分量应放在同一批更新中；任一失败均保持两个输出原值。
    /// 不扫描未编辑字段，也不替代完整参数诊断。限幅不修复矩阵、曲线或权重组。
    /// 仅在外部值变化时按需调用；共享模型快照的发布与线程同步由调用方负责。
    @discardableResult
    public static func update(_ changes: [ControlOverride], parameters: inout StyleParameters,
                              lutWeights: inout [ResourceWeight], domain: ParameterValueDomain = .base,
                              behavior: ParameterRangeBehavior = .reject) throws -> [ControlDiagnostic] {
        try ParameterSpecification.validateOwners(changes.map(\.target))
        var next = parameters, weights = lutWeights, diagnostics: [ControlDiagnostic] = []
        for change in changes {
            let spec = try ParameterSpecification.lookup(change.target)
            var value = change.value
            if case .scalar(let number) = value {
                guard number.isFinite else { throw LabError.invalid("\(change.target): expected a finite value") }
                if behavior == .clamp {
                    let range = domain == .effective ? spec.effectiveRange : spec.baseRange
                    let limited = min(range.upperBound, max(range.lowerBound, number))
                    value = .scalar(limited)
                    if limited != number { diagnostics.append(.init(code: .clamped, target: change.target)) }
                }
            }
            try ControlAccess.apply(value, target: change.target, parameters: &next, lutWeights: &weights,
                                    effective: domain == .effective)
        }
        let targets = changes.map(\.target)
        if targets.contains(where: { $0.hasPrefix("color.whiteBalance.source.") }) {
            try validateField("color.whiteBalance.source") { try next.color.whiteBalance.source.validate() }
        }
        if targets.contains(where: { $0.hasPrefix("color.whiteBalance.destination.") }) {
            try validateField("color.whiteBalance.destination") { try next.color.whiteBalance.destination.validate() }
        }
        if targets.contains(where: { $0.hasPrefix("color.matrix.") }) {
            try validateField("color.matrix") { try next.color.matrix.validate() }
        }
        parameters = next; lutWeights = weights
        return diagnostics
    }

    /// 按指定用途诊断曲线，成功时原样返回；不重排节点或修复曲线。
    public static func curve(_ value: ResponseCurve, kind: ImageResponseKind) throws -> ResponseCurve {
        try value.validate(kind: kind)
        return value
    }

    /// 在适配规则创建或修改后按需诊断，成功时原样返回。
    /// 不应在每帧适配前重复调用；此方法不建立后续执行使用的校验凭据。
    public static func adaptationPolicy(_ value: AdaptationPolicy) throws -> AdaptationPolicy {
        try value.validate()
        return value
    }
}
