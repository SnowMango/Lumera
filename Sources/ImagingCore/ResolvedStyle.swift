import Foundation

/// Final caller-resolved settings. No merging or implicit parameter policy.
public struct ResolvedStyle: Equatable, Sendable {
    public let parameters:StyleParameters
    public let temporalPolicy:TemporalPolicy
    public let profileDigest:String,effectiveDigest:String
    public init(parameters:StyleParameters,profileDigest:String? = nil,temporalPolicy:TemporalPolicy=TemporalPolicy()) throws {
        try parameters.validate(resolved:true)
        self.parameters=parameters;self.temporalPolicy=temporalPolicy
        struct Content:Encodable {let parameters:StyleParameters;let temporalPolicy:TemporalPolicy}
        self.effectiveDigest=Digest.data(try JSON.encode(Content(parameters:parameters,temporalPolicy:temporalPolicy)))
        self.profileDigest=profileDigest ?? effectiveDigest
    }
    /// Convenience for an unmodified saved style; never applies photo adjustments.
    public init(profile:Profile) throws {
        self=try StyleEvaluator.evaluate(StyleEvaluator.compile(profile)).resolvedStyle()
    }
}
