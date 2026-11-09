import Foundation

/// Pixel-processing settings shared by texture, Core Image, pixel-buffer and RAW entry points.
/// These settings do not describe the source color space and never overwrite capture EXIF values.
public struct RenderOptions: Codable, Equatable, Sendable {
    /// Explicit opt-in to extended-range input/output. Existing callers remain SDR.
    public var dynamicRange: RenderDynamicRange = .sdr
    /// Bounds declared by borrowed-texture callers; native image adapters measure their own input.
    public var inputValueBounds: NumericBounds?
    /// Optional output long-edge limit. Nil preserves dimensions; a limit must be positive.
    public var maximumLongEdge: Int?
    /// Base seed used by the style's temporal noise/grain policy.
    public var seed: UInt32
    /// Frame sequence number used by the style's temporal policy; not a presentation timestamp.
    public var frameIndex: UInt32
    /// Whether glow and halation are evaluated. Does not change the prepared style.
    public var previewGlow = true
    /// Resolution of the intermediate glow layer, not the final output.
    public var glowScale: EffectResolution = .full
    /// Resolution of the intermediate halation layer, not the final output.
    public var halationScale: EffectResolution = .full
    /// Resolution of the intermediate softening layer, not the final output.
    public var softeningScale: EffectResolution = .full

    /// Creates full-resolution effect settings with deterministic seed 42 and frame index 0.
    public init(maximumLongEdge: Int? = nil, seed: UInt32 = 42, frameIndex: UInt32 = 0) {
        self.maximumLongEdge = maximumLongEdge
        self.seed = seed
        self.frameIndex = frameIndex
    }

    /// Builds a request for the existing encoder. The encoder validates it before encoding.
    /// Image adapters supply their normalized input descriptor automatically.
    public func makeRequest(input: InputDescriptor) -> RenderRequest {
        var request = RenderRequest(input: input, maximumLongEdge: maximumLongEdge)
        request.seed = seed
        request.frameIndex = frameIndex
        request.previewGlow = previewGlow
        request.glowScale = glowScale
        request.halationScale = halationScale
        request.softeningScale = softeningScale
        request.dynamicRange = dynamicRange
        request.inputValueBounds = inputValueBounds
        return request
    }

    private enum CodingKeys: String, CodingKey {
        case dynamicRange, inputValueBounds, maximumLongEdge, seed, frameIndex, previewGlow, glowScale, halationScale, softeningScale
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inputValueBounds = try c.decodeIfPresent(NumericBounds.self, forKey: .inputValueBounds)
        dynamicRange = try c.decodeIfPresent(RenderDynamicRange.self, forKey: .dynamicRange) ?? .sdr
        maximumLongEdge = try c.decodeIfPresent(Int.self, forKey: .maximumLongEdge)
        seed = try c.decode(UInt32.self, forKey: .seed)
        frameIndex = try c.decode(UInt32.self, forKey: .frameIndex)
        previewGlow = try c.decode(Bool.self, forKey: .previewGlow)
        glowScale = try c.decode(EffectResolution.self, forKey: .glowScale)
        halationScale = try c.decode(EffectResolution.self, forKey: .halationScale)
        softeningScale = try c.decode(EffectResolution.self, forKey: .softeningScale)
    }
}
