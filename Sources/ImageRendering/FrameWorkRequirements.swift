import Metal
import ImagingCore

/// Mathematical activity cached with resolved parameters, independent of frame ownership.
struct PreparedEffectActivity {
    let ordinary: Bool
    let opticalPreview: Bool
    init(_ p: StyleParameters) {
        ordinary = p.color.isActive || p.tone.isActive || p.detail.isActive ||
            p.softening.isActive || p.vignette.isActive || p.noise.isActive || p.grain.isActive
        opticalPreview = p.glow.isActive || p.halation.isActive
    }
}

/// Shared by the encoder's identity return and the model submission boundary.
struct FrameWorkRequirements {
    let requiresPixelProcessing: Bool
    init(hasEffects: Bool, needsResize: Bool, inputFormat: MTLPixelFormat, outputFormat: MTLPixelFormat) {
        requiresPixelProcessing = hasEffects || needsResize || inputFormat != outputFormat
    }
}
