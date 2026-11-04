import Foundation

public struct RenderRequest: Codable, Equatable, Sendable {
    public var dynamicRange: RenderDynamicRange = .sdr
    public var input:InputDescriptor
    public var maximumLongEdge:Int?
    public var seed:UInt32=42,frameIndex:UInt32=0
    public var previewGlow=true
    public var glowScale:EffectResolution = .full
    public var halationScale:EffectResolution = .full
    public var softeningScale:EffectResolution = .full
    public init(input:InputDescriptor,maximumLongEdge:Int? = nil) {self.input=input;self.maximumLongEdge=maximumLongEdge}
    public func validate() throws {
        try input.validate()
        if let limit=maximumLongEdge, limit<1 {throw LabError.invalid("效果长边必须为正整数")}
    }
    private enum CodingKeys: String, CodingKey {
        case dynamicRange, input, maximumLongEdge, seed, frameIndex, previewGlow, glowScale, halationScale, softeningScale
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dynamicRange = try c.decodeIfPresent(RenderDynamicRange.self, forKey: .dynamicRange) ?? .sdr
        input = try c.decode(InputDescriptor.self, forKey: .input)
        maximumLongEdge = try c.decodeIfPresent(Int.self, forKey: .maximumLongEdge)
        seed = try c.decode(UInt32.self, forKey: .seed)
        frameIndex = try c.decode(UInt32.self, forKey: .frameIndex)
        previewGlow = try c.decode(Bool.self, forKey: .previewGlow)
        glowScale = try c.decode(EffectResolution.self, forKey: .glowScale)
        halationScale = try c.decode(EffectResolution.self, forKey: .halationScale)
        softeningScale = try c.decode(EffectResolution.self, forKey: .softeningScale)
    }
}
