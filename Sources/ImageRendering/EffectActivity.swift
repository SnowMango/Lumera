import ImagingCore

/// Stage selection shared by encoding, tile support and precision accounting.
/// This describes mathematical activity only; it does not fuse effect implementations.
struct EffectActivity {
    let detailBands: Bool
    let sharpening: Bool
    let linearOptics: Bool

    init(_ parameters: StyleParameters, previewGlow: Bool) {
        let detail = parameters.detail
        detailBands = detail.enabled && (detail.fineGain != 1 || detail.midGain != 1)
        sharpening = detail.enabled && detail.sharpenAmount > 0
        linearOptics = parameters.softening.isActive || parameters.vignette.isActive ||
            (previewGlow && (parameters.glow.isActive || parameters.halation.isActive))
    }
}
