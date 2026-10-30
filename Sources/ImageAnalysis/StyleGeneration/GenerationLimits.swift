import Foundation
import ImagingCore

/// Every case compares a nonnegative error to a frozen absolute/relative budget.
/// Statistical cases must provide their own independent reference and fixed seed set.
public struct GenerationLimit:Codable,Equatable,Sendable {
    public var caseID:String,unit:String,validDomain:String,absoluteTolerance:Double,relativeTolerance:Double,referenceMagnitude:Double
    public func accepts(_ error:Double)->Bool {error.isFinite && error>=0 && error<=absoluteTolerance+relativeTolerance*abs(referenceMagnitude)}
}
public enum GenerationLimits {
    public static let version="generation-limits-6",algorithmVersion="generation-contract-6"
    public static let implemented:Set<AlgorithmID>=[.independentLUT,.targetDetection,.captureQuality,.toneColor,.detail,.texture,.glow,.conditionResponse,.combinedValidation]
    public static let materialDefinition="Lumera independent LUT reference v1; RGB=(0.2,0.4,0.8); correction swap R/B; style cycle G/B/R; creative B/G/R; half LUT; seed=1729; detail Double oracle v3 distinct exposures/repeats, broadband plus missing-high-band refusal, interior ROI weighted ESF; texture independent normal grids v1 seeds1729/99173/4291; light Double RGB rings/convolution v1 core geometry/outside rejection; ISO independent three-condition noise and nonmonotonic holdout; combined actual-band-energy plus distinct actual ISO and actual baseline regression"
    public static let fixtureManifestDigest="d2d4460832d6ce0281efecd58a9ffe1a4bf4ce09cc07c6995c637e7a86192ee4"
    public static let materialDigest=Digest.data(Data((materialDefinition+fixtureManifestDigest).utf8))
    public static func cases(for id:AlgorithmID)->[GenerationLimit] {
        func limit(_ name:String,_ unit:String,_ tolerance:Double,_ domain:String)->GenerationLimit {
            .init(caseID:name,unit:unit,validDomain:domain,absoluteTolerance:tolerance,relativeTolerance:0,referenceMagnitude:1)
        }
        switch id {
        case .independentLUT:return [
            limit("serialization","forbidden fields",0,"Profile and DeviceCorrection; no LUT bytes/path/ID"),
            limit("none","encoded sRGB max channel error",0,"normalized SDR opaque RGB"),
            limit("lutOnly","encoded sRGB max channel error",0.0001,"2x2x2 linear cube; Float32"),
            limit("combinedOrder","encoded sRGB max channel error",0.0001,"noncommuting correction/style/LUT; Float32"),
            limit("dynamic","encoded sRGB max channel error",0.0001,"ISO 100 and 400; 0/1 EV vignette; fixed LUT"),
            limit("invalidAsset","accepted invalid assets",0,"bad digest/contract/incomplete cube"),
            limit("cacheIdentity","incorrect reuse or extra uploads",0,"same-name different content; unchanged LUT and changed style")]
        case .targetDetection:return [limit("geometry","source pixel max reprojection error",1,"four visible markers; no crop; shortest edge >= 1200 px"),limit("rejectInvalidBoard","false accept count",0,"wrong version, missing/cropped marker"),limit("realGeometry","source pixel max error",1,"independently annotated camera photos; real print")]
        case .captureQuality:return [limit("patchStatistics","maximum mean/variance absolute error",0.000001,"independent Double reference; no resampling"),limit("rejectUnsafeCapture","false accept count",0,"clipping, glare, duplicates, missing required metadata, mismatched roles"),limit("realRejection","false accept count",0,"independently labelled real capture failures")]
        case .toneColor:return [limit("patchPixelValidation","encoded RGB rendered patch mean error",0.0004,"nonuniform 0.21/0.29 checker; nonlinear tone; original-pixel GPU ROI reduction"),limit("canonicalMatrix","maximum linear RGB matrix coefficient error",0.012,"sum=3 near-identity matrix; independent neutral/tinted analytical references; +/- 0.0001 perturbations"),limit("anchoredTone","maximum encoded RGB knot error",0.006,"monotone 0/0.5/1 anchored curve; 0.25 and 0.75 free knots"),limit("heldOutColor","encoded sRGB max channel error",0.015,"unclipped relative samples; fixed exposure/white balance; SDR"),limit("rejectAmbiguousColor","false accept count",0,"rank-deficient patches, exposure ambiguity, conflicting LUT")]
        case .detail:return [limit("fineRecovery","fine gain absolute error",0.08,"independent Double reference; 2048/2560; fixed radii"),limit("softnessRecovery","softness absolute error",0.04,"independent Double reference; 2048/2560; fixed radii"),limit("edgeResponse","normalized edge profile RMSE",0.01,"native matching scale; shortest edge >=2048; source MTF50 >0.04; broadband texture; no resampling"),limit("rejectAmbiguousDetail","false accept count",0,"softening/sharpening cancellation, already softer input")]
        case .texture:return [limit("amplitudeRecovery","relative sigma error",0.06,"independent digital noise/correlated grain; fixed spatial/chroma family"),limit("variance","relative variance error",0.10,"independent repeats; non-clipped patches; fixed seed suite"),limit("rejectAmbiguousTexture","false accept count",0,"paper texture, compression, already noisier input")]
        case .glow:return [limit("rgbReduction","maximum linear RGB mean error",0.000001,"independent Double sector annulus reference; native pixels"),limit("amountRecovery","maximum diffusion amount error",0.03,"independent Double convolution; fixed scales/threshold/tint"),limit("radialResponse","peak-normalized RGB sector RMSE",0.01,"unclipped near-circular source; dark background; matching core geometry; fixed angular scale"),limit("rejectAmbiguousGlow","false accept count",0,"near/far ghosts, clipped source, absent background, actual baseline regression")]
        case .conditionResponse:return [limit("heldOutCondition","relative response error",0.10,"measured source ISO; withheld middle group; no causal multi-axis claim"),limit("rejectUnsupportedAxis","false accept count",0,"missing axis, duplicate or insufficient levels")]
        case .combinedValidation:return [limit("perModuleRegression","failed module/condition count",0,"each module meets its own budget; unseen middle and extreme conditions")]
        }
    }
}
