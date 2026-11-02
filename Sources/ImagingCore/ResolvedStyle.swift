import Foundation

/// Final caller-resolved settings, with exposure limited to its effective range.
public struct ResolvedStyle: Equatable, Sendable {
    public let parameters:StyleParameters
    public let temporalPolicy:TemporalPolicy
    public let profileDigest:String,effectiveDigest:String
    public init(parameters:StyleParameters,profileDigest:String? = nil,temporalPolicy:TemporalPolicy=TemporalPolicy()) throws {
        var parameters = parameters
        parameters.color.exposureEV = ColorResponse.limitedExposure(parameters.color.exposureEV, resolved: true)
        try parameters.validate(resolved:true)
        self.parameters=parameters;self.temporalPolicy=temporalPolicy
        self.effectiveDigest = try StyleIdentity.validatedEffectiveDigest(parameters:parameters, temporalPolicy:temporalPolicy)
        self.profileDigest=profileDigest ?? effectiveDigest
    }
    /// Convenience for an unmodified saved style; never applies photo adjustments.
    public init(profile:Profile) throws {
        self=try StyleEvaluator.evaluate(StyleEvaluator.compile(profile)).resolvedStyle()
    }
}
