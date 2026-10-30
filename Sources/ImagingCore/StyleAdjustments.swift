import Foundation

public struct StyleAdjustments: Codable, Equatable, Sendable {
    public var exposureEV=0.0
    public var whiteBalanceOverride: WhiteBalanceCorrection?
    public var softeningMultiplier=1.0, noiseMultiplier=1.0, grainMultiplier=1.0, glowMultiplier=1.0, halationMultiplier=1.0
    public init() {}
    public func validate() throws {
        guard exposureEV.isFinite,(-3...3).contains(exposureEV),
              [softeningMultiplier,noiseMultiplier,grainMultiplier,glowMultiplier,halationMultiplier].allSatisfy({$0.isFinite && (0...2).contains($0)}) else {throw LabError.invalid("照片调整超出允许范围")}
        try whiteBalanceOverride?.validate()
    }
}
