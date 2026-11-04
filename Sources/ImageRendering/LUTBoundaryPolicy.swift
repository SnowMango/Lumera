import ImagingCore

/// Behavior outside a LUT's authored 0...1 encoded-sRGB input domain.
/// Independent of any future shaper/input-coordinate mapping.
public enum LUTBoundaryPolicy: String, Codable, Sendable {
    /// Preserve legacy clamping for SDR; extrapolate when rendering EDR.
    case automatic
    case clamp
    /// Continue the closest boundary cell's trilinear function, including at corners.
    /// The result is inferred, not an authored HDR look or Apple's private algorithm.
    case extrapolate

    package func extrapolates(in range: RenderDynamicRange) -> Bool {
        self == .extrapolate || (self == .automatic && range == .edr)
    }
}
