/// Processing/output range, independent of RGB primaries and transfer function.
public enum RenderDynamicRange: String, Codable, Sendable {
    /// Existing bounded sRGB rendering behavior.
    case sdr
    /// Preserve signed extended-sRGB values, including highlights above SDR white.
    /// Texture callers supply encoded extended sRGB with the same reference white as SDR.
    /// This does not synthesize HDR, choose an exposure, or adapt to a display's headroom.
    case edr
}
