import Foundation

public struct StyleParameters: Codable, Equatable, Sendable {
    public var color=ColorResponse()
    public var tone=ToneResponse(), detail=Detail(), softening=Softening()
    public var vignette=Vignette(), glow=Glow(), halation=Halation()
    public var noise=Noise(), grain=FilmGrain()
    public init() {}
    public func validate(resolved: Bool = false) throws {
        try validateField("$.parameters.tone.curve") { try tone.curve.validate(kind: .tone) }
        try validateField("$.parameters.noise.curve") { try noise.curve.validate(kind: .noise) }
        try validateField("$.parameters.grain.luminanceCurve") { try grain.luminanceCurve.validate(kind: .grain) }
        // Validate array lengths before indexed key paths.
        try validateField("$.parameters.color.matrix.values") { try color.matrix.validate() }
        try validateField("$.parameters.color.whiteBalance.source") { try color.whiteBalance.source.validate() }
        try validateField("$.parameters.color.whiteBalance.destination") { try color.whiteBalance.destination.validate() }
        for item in ParameterDescriptor.all {
            let value=self[keyPath:item.keyPath]
            let range: ClosedRange<Double> = resolved ? item.effectiveRange : item.baseRange
            guard value.isFinite, range.contains(value) else { throw LabError.invalid("$.parameters.\(item.id): 参数“\(item.title)”超出有效范围") }
        }
        guard detail.midSigma >= detail.fineSigma else {
            throw LabError.invalid("$.parameters.detail.midSigma: 小于 fineSigma")
        }
        guard glow.farSigma >= glow.nearSigma else {
            throw LabError.invalid("$.parameters.glow.farSigma: 小于 nearSigma")
        }

    }
}
