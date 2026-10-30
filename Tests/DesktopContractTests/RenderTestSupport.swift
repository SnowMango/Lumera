import ImagingCore
import ImageRendering
import ImageAnalysis

// Test construction helpers only; production exposes only ResolvedStyle + RenderRequest.
enum TestProfiles {
    static var ccd:Profile {
        var p=Profile.standard
        p.parameters.detail.enabled=true;p.parameters.detail.fineGain=0.88;p.parameters.detail.midGain=0.98;p.parameters.detail.sharpenAmount=0.10
        p.parameters.vignette.enabled=true;p.parameters.vignette.amountEV=0.45
        p.parameters.glow.enabled=true;p.parameters.glow.amount=0.08
        p.parameters.noise.enabled=true;p.parameters.noise.curve = .init(knots:zip([0.0,0.18,0.5,0.85,1],[0.012,0.008,0.004,0.002,0.001]).map{.init(x:$0,y:$1)})
        return p
    }
}
extension MetalRenderer {
    func renderStyle(_ image:ImageFrame,profile:Profile,maximumLongEdge:Int?=nil,seed:UInt32=42,frameIndex:UInt32=0,previewGlow:Bool=true) throws -> RenderResult {
        var request=RenderRequest(input:image.descriptor,maximumLongEdge:maximumLongEdge)
        request.seed=seed;request.frameIndex=frameIndex;request.previewGlow=previewGlow
        return try render(image,style:ResolvedStyle(profile:profile),request:request)
    }
}
