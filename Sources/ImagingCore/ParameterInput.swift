import Foundation

public enum ParameterValueDomain: Sendable { case base, effective }
public enum ParameterRangeBehavior: Sendable { case reject, clamp }

/// Explicit input handling. Execution does not call these methods or retain validation state.
public enum ParameterInput {
    public static func accept(_ parameters: StyleParameters,
                              domain: ParameterValueDomain = .base) throws -> StyleParameters {
        try parameters.validate(resolved: domain == .effective)
        return parameters
    }

    /// Applies only changed controls and their compound fields. Failure leaves both outputs unchanged.
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

    public static func curve(_ value: ResponseCurve, kind: ImageResponseKind) throws -> ResponseCurve {
        try value.validate(kind: kind)
        return value
    }

    public static func adaptationPolicy(_ value: AdaptationPolicy) throws -> AdaptationPolicy {
        try value.validate()
        return value
    }
}
