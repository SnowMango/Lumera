import Foundation
import ImagingCore

/// 标识影响渲染的设置。缓存成品时需一并纳入来源身份。
public enum RenderIdentity {
    /// 验证资源与请求，并计算包含有效参数、精度、区域及启用随机效果种子的标识。
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
            let dynamicRange: RenderDynamicRange?
            let styleLUTBoundary: LUTBoundaryPolicy?, correctionLUTBoundary: LUTBoundaryPolicy?
        }
        try request.validate()
        if let region {
            let longEdge = max(request.input.width, request.input.height)
            let scale = Double(min(longEdge,request.maximumLongEdge ?? longEdge))/Double(longEdge)
            let frame = CGRect(x:0,y:0,width:max(1,Int(Double(request.input.width)*scale)),
                               height:max(1,Int(Double(request.input.height)*scale)))
            guard region == region.integral, !region.isEmpty, frame.contains(region) else { throw LabError.invalid("无效的渲染区域") }
        }
        let identity = RenderResourceIdentity(validated: resources)
        let settings = Settings(revision: rendererRevision, effects: style.effectiveDigest,
            precision: precision == .float16 ? "float16" : "float32", region: region, size: request.input,
            limit: request.maximumLongEdge, glow: request.previewGlow,
            scales: [request.glowScale, request.softeningScale, request.halationScale],
            grainSeed: style.parameters.grain.isActive ? style.temporalPolicy.grain.seed(request.seed, frameIndex: request.frameIndex) : nil,
            noiseSeed: style.parameters.noise.isActive ? style.temporalPolicy.noise.seed(request.seed, frameIndex: request.frameIndex) : nil,
            styleLUT: identity.styleLUT?.sha256, correctionLUT: identity.correctionLUT?.sha256,
            correction: try correction?.effectDigest(),
            dynamicRange: request.dynamicRange == .sdr ? nil : request.dynamicRange,
            styleLUTBoundary: identity.styleLUT.flatMap { $0.boundaryPolicy == .automatic ? nil : $0.boundaryPolicy },
            correctionLUTBoundary: identity.correctionLUT.flatMap { $0.boundaryPolicy == .automatic ? nil : $0.boundaryPolicy })
        return Digest.data(try JSON.encode(settings))
    }
}
