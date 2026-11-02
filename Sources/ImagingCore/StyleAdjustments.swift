import Foundation

public struct StyleAdjustments: Codable, Equatable, Sendable {
    public var exposureEV = 0.0 {
        didSet { exposureEV = ColorResponse.limitedExposure(exposureEV) }
    }
    public var whiteBalanceOverride: WhiteBalanceCorrection?
    public var softeningMultiplier=1.0, noiseMultiplier=1.0, grainMultiplier=1.0, glowMultiplier=1.0, halationMultiplier=1.0
    public init() {}
    public init(from decoder: Decoder) throws {
        var result = Self()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        result.exposureEV = try values.decode(Double.self, forKey: .exposureEV)
        result.whiteBalanceOverride = try values.decodeIfPresent(WhiteBalanceCorrection.self, forKey: .whiteBalanceOverride)
        result.softeningMultiplier = try values.decode(Double.self, forKey: .softeningMultiplier)
        result.noiseMultiplier = try values.decode(Double.self, forKey: .noiseMultiplier)
        result.grainMultiplier = try values.decode(Double.self, forKey: .grainMultiplier)
        result.glowMultiplier = try values.decode(Double.self, forKey: .glowMultiplier)
        result.halationMultiplier = try values.decode(Double.self, forKey: .halationMultiplier)
        self = result
    }

    public func validate() throws {
        guard exposureEV.isFinite,ColorResponse.exposureRange.contains(exposureEV),
              [softeningMultiplier,noiseMultiplier,grainMultiplier,glowMultiplier,halationMultiplier].allSatisfy({$0.isFinite && (0...2).contains($0)}) else {throw LabError.invalid("照片调整超出允许范围")}
        try whiteBalanceOverride?.validate()
    }
}
