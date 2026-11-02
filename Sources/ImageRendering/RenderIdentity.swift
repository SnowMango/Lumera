import Foundation
import ImagingCore

/// Identifies processing settings. A finished image cache additionally needs source identity.
public enum RenderIdentity {
    public static func make(style: ResolvedStyle, resources: RenderResources = .init(),
                            correction: DeviceCorrection? = nil, request: RenderRequest,
                            precision: RenderingPrecision, region: CGRect? = nil, rendererRevision: String = LumeraVersion.rendererRevision) throws -> String {
        try resources.validate()
        return try fromValidated(style: style, resources: resources, correction: correction, request: request,
                                 precision: precision, region: region, rendererRevision: rendererRevision)
    }

    package static func fromValidated(style: ResolvedStyle, resources: RenderResources, correction: DeviceCorrection?,
                                      request: RenderRequest, precision: RenderingPrecision, region: CGRect? = nil,
                                      rendererRevision: String = LumeraVersion.rendererRevision) throws -> String {
        struct Settings: Encodable {
            let revision: String, effects: String, precision: String
            let region: CGRect?
            let size: InputDescriptor, limit: Int?, glow: Bool, scales: [EffectResolution]
            let grainSeed: UInt32?, noiseSeed: UInt32?
            let styleLUT: String?, correctionLUT: String?, correction: String?
        }
        try request.validate()
        if let region {
            let longEdge = max(request.input.width, request.input.height)
            let scale = Double(min(longEdge,request.maximumLongEdge ?? longEdge))/Double(longEdge)
            let frame = CGRect(x:0,y:0,width:max(1,Int(Double(request.input.width)*scale)),
                               height:max(1,Int(Double(request.input.height)*scale)))
            guard region == region.integral, !region.isEmpty, frame.contains(region) else { throw LabError.invalid("无效的渲染区域") }
        }
        let settings = Settings(revision: rendererRevision, effects: style.effectiveDigest,
            precision: precision == .float16 ? "float16" : "float32", region: region, size: request.input,
            limit: request.maximumLongEdge, glow: request.previewGlow,
            scales: [request.glowScale, request.softeningScale, request.halationScale],
            grainSeed: style.parameters.grain.isActive ? style.temporalPolicy.grain.seed(request.seed, frameIndex: request.frameIndex) : nil,
            noiseSeed: style.parameters.noise.isActive ? style.temporalPolicy.noise.seed(request.seed, frameIndex: request.frameIndex) : nil,
            styleLUT: resources.lut?.sha256, correctionLUT: resources.correctionLUT?.sha256,
            correction: try correction?.effectDigest())
        return Digest.data(try JSON.encode(settings))
    }
}
