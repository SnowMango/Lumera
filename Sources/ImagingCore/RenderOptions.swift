import Foundation

/// Pixel-processing settings shared by texture, Core Image, pixel-buffer and RAW entry points.
/// These settings do not describe the source color space and never overwrite capture EXIF values.
public struct RenderOptions: Codable, Equatable, Sendable {
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
        return request
    }
}
