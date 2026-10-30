import ImagingCore

/// Common uniform layout for the texture and offline renderers.
public enum CameraEffectUniforms {
    public static let kernels=["colorResponse","toneResponse","softenCombine","halationCombine","filmGrain","opticalReduce","softenCombineReduced","glowCombineReduced","halationCombineReduced"]
    public static func tone(_ value:ToneResponse)->[Float] {PreparedResponseCurves({var p=StyleParameters();p.tone=value;return p}()).tone}
    public static func noise(_ value:Noise)->[Float] { [value.isActive ? 1:0,Float(value.chromaRatio),Float(value.chromaCorrelation),Float(value.gain)]+PreparedResponseCurves.encode(value.curve) }
    public static func halation(_ value:Halation)->[Float] {[value.amount,value.red,value.green,value.blue].map(Float.init)}
    public static func grain(_ value:FilmGrain,scale:Double,seed:UInt32,frameIndex:UInt32=0,envelope:[Float]?=nil)->[Float] {
        [Float(value.amount),Float(max(EffectScale.minimumGrainPixels,value.size*scale)),Float(value.roughness),Float(value.chroma),Float(bitPattern:seed ^ (frameIndex &* 0x9e3779b9))] + (envelope ?? PreparedResponseCurves.encode(value.luminanceCurve))
    }
}
