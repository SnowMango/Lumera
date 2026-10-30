import Foundation

public struct StyleParameters: Codable, Equatable, Sendable {
    public var color=ColorResponse()
    public var tone=ToneResponse(), detail=Detail(), softening=Softening()
    public var vignette=Vignette(), glow=Glow(), halation=Halation()
    public var noise=Noise(), grain=FilmGrain()
    public init() {}
    public func validate(resolved: Bool = false) throws {
        guard noise.gain.isFinite,(0...8).contains(noise.gain) else {throw LabError.invalid("噪点倍率须为0–8") }
        try tone.curve.validate(kind:.tone)
        try noise.curve.validate(kind:.noise)
        try grain.luminanceCurve.validate(kind:.grain)
        try color.validate(resolved:resolved) // Validate array lengths before indexed key paths.
        for item in ParameterDescriptor.all {
            let value=self[keyPath:item.keyPath]
            let range: ClosedRange<Double> = resolved && item.id == "color.exposureEV" ? -6...6 : item.range
            guard value.isFinite, range.contains(value) else { throw LabError.invalid("参数“\(item.title)”超出有效范围") }
        }
        guard detail.midSigma >= detail.fineSigma, glow.farSigma >= glow.nearSigma else {
            throw LabError.invalid("模糊尺度顺序无效")
        }
        try color.validate(resolved:resolved)

    }
}
