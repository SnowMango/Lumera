import ImagingCore

/// Storage and Gaussian-weight requirements, excluding coefficients that only change uniforms.
/// This follows the existing effect graph; it does not merge or alter effect algorithms.
struct ProcessingResourceShape: Equatable {
    let values: [Double]
    init(_ p: StyleParameters, style: PreparedResolvedStyle, correction: PreparedDeviceCorrection?, request: RenderRequest) {
        let a = EffectActivity(p, previewGlow: request.previewGlow)
        func flag(_ value: Bool) -> Double { value ? 1 : 0 }
        values = [flag(p.color.isActive), flag(p.tone.isActive), flag(style.hasProcessingLUT),
            flag(correction?.colorIsActive == true), flag(correction?.lutTexture != nil),
            flag(a.detailBands), a.detailBands ? p.detail.fineSigma : 0, a.detailBands ? p.detail.midSigma : 0,
            flag(a.sharpening), a.sharpening ? p.detail.sharpenSigma : 0,
            flag(p.softening.isActive), p.softening.isActive ? p.softening.sigma : 0, flag(p.vignette.isActive),
            flag(request.previewGlow && p.glow.isActive), request.previewGlow && p.glow.isActive ? p.glow.nearSigma : 0,
            request.previewGlow && p.glow.isActive ? p.glow.farSigma : 0,
            flag(request.previewGlow && p.halation.isActive), request.previewGlow && p.halation.isActive ? p.halation.radius : 0,
            flag(p.noise.isActive), p.noise.isActive ? p.noise.lumaSigma : 0, p.noise.isActive ? p.noise.chromaSigma : 0,
            flag(p.grain.isActive), p.grain.isActive ? p.grain.size : 0, p.grain.isActive ? p.grain.roughness : 0]
    }
}
