import Foundation

public struct RenderRequest: Codable, Equatable, Sendable {
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
}
