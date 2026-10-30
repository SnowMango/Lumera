import Foundation

public struct CompiledStyleDefinition:Sendable {
    public let parameters:StyleParameters
    public let responses:[ConditionBinding]
    public let temporalPolicy:TemporalPolicy
    /// Content identity computed once, including curves/time policy and static LUT.
    public let identity:String
    fileprivate init(_ profile:Profile) throws {
        parameters=profile.parameters;responses=profile.responses;temporalPolicy=profile.temporalPolicy
        identity=try profile.effectDigest()
    }
}
public enum ResponseStatus:String,Codable,Sendable {case applied,missingCondition}
public struct ResponseDiagnostic:Codable,Equatable,Sendable {
    public let target:ResponseTarget,axis:ConditionAxis,status:ResponseStatus
    public let condition:Double?,response:Double?
}
public struct EvaluatedStyle:Sendable {
    public let parameters:StyleParameters
    public let definitionIdentity:String
    public let temporalPolicy:TemporalPolicy
    public let diagnostics:[ResponseDiagnostic]
    public let adjustmentLimits:[String]
    /// Offline boundary only; frame encoders use parameters directly without hashing JSON.
    public func resolvedStyle() throws -> ResolvedStyle {try ResolvedStyle(parameters:parameters,profileDigest:definitionIdentity,temporalPolicy:temporalPolicy)}
}
public enum StyleEvaluator {
    public static func compile(_ profile:Profile) throws -> CompiledStyleDefinition {
        try profile.validate();return try CompiledStyleDefinition(profile)
    }
    static func validateResponses(_ responses:[ConditionBinding],parameters:StyleParameters) throws {
        guard responses.count<=ResponseTarget.allCases.count,Set(responses.map(\.target)).count==responses.count else {throw LabError.invalid("每个效果参数最多绑定一条条件响应")}
        for binding in responses {
            try binding.curve.validate(axis:binding.axis)
            for value in [binding.curve.outputRange.lowerBound,binding.curve.outputRange.upperBound] {
                var p=parameters
                try binding.target.apply(value,operation:binding.operation,to:&p)
                try p.validate()
            }
        }
    }
    public static func evaluate(_ definition:CompiledStyleDefinition,conditions:CaptureConditions=CaptureConditions(),adjustments:StyleAdjustments=StyleAdjustments()) throws -> EvaluatedStyle {
        try conditions.validate();try adjustments.validate()
        var p=definition.parameters,diagnostics=[ResponseDiagnostic](),limits=[String]()
        for binding in definition.responses {
            guard let input=conditions[binding.axis] else {
                diagnostics.append(.init(target:binding.target,axis:binding.axis,status:.missingCondition,condition:nil,response:nil));continue
            }
            let value=binding.curve.sampleValidated(at:input,axis:binding.axis)
            try binding.target.apply(value,operation:binding.operation,to:&p)
            diagnostics.append(.init(target:binding.target,axis:binding.axis,status:.applied,condition:input,response:value))
        }
        p.color.exposureEV += adjustments.exposureEV
        if let white=adjustments.whiteBalanceOverride {p.color.whiteBalance=white}
        func amount(_ value:Double,_ multiplier:Double,_ maximum:Double,_ id:String)->Double {
            let result=value*multiplier
            if result>maximum {limits.append(id)}
            return min(maximum,result)
        }
        p.softening.amount=amount(p.softening.amount,adjustments.softeningMultiplier,1,"softening.amount")
        p.grain.amount=amount(p.grain.amount,adjustments.grainMultiplier,0.1,"grain.amount")
        p.glow.amount=amount(p.glow.amount,adjustments.glowMultiplier,1,"glow.amount")
        p.halation.amount=amount(p.halation.amount,adjustments.halationMultiplier,1,"halation.amount")
        p.noise.gain=amount(p.noise.gain,adjustments.noiseMultiplier,8,"noise.gain")
        if p.noise.curve.outputRange.upperBound*p.noise.gain>0.1 {limits.append("noise.amplitude") }
        try p.validate(resolved:true)
        return EvaluatedStyle(parameters:p,definitionIdentity:definition.identity,temporalPolicy:definition.temporalPolicy,diagnostics:diagnostics,adjustmentLimits:limits)
    }
}
