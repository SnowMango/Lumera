import ImagingCore

/// Common uniform layout for the texture and offline renderers.
public enum EffectUniforms {
    public static let kernels=["colorResponse","toneResponse","softenCombine","halationCombine","filmGrain","grainSubpixels","grainReduce","opticalReduce","softenCombineReduced","glowCombineReduced","halationCombineReduced"]
    public static func tone(_ value:ToneResponse)->[Float] {PreparedResponseCurves({var p=StyleParameters();p.tone=value;return p}()).tone}
    public static func noise(_ value:Noise, envelope:[Float]? = nil)->[Float] { [value.isActive ? 1:0,Float(value.chromaRatio),Float(value.chromaCorrelation),Float(value.gain)]+(envelope ?? PreparedResponseCurves.encode(value.curve)) }
    public static func halation(_ value:Halation)->[Float] {[value.amount,value.red,value.green,value.blue].map(Float.init)}
    public static func grain(_ value: FilmGrain, scale: Double, seed: UInt32, frameIndex: UInt32 = 0,
                             envelope: [Float]? = nil) throws -> [Float] {
        var parameters = StyleParameters()
        parameters.grain = value
        try parameters.validate(resolved:true)
        guard scale.isFinite, (1/EffectScale.referenceLongEdge...Double(1 << 24)/EffectScale.referenceLongEdge).contains(scale) else {
            throw LabError.invalid("颗粒输出尺度无效")
        }
        return grain(value,scale:scale,seed:seed,frameIndex:frameIndex,envelope:envelope,
                     prepared:PreparedGrain(size:value.size,roughness:value.roughness))
    }

    package static func grain(_ value: FilmGrain, scale: Double, seed: UInt32, frameIndex: UInt32,
                              envelope: [Float]? = nil, originX: Int = 0, originY: Int = 0,
                              prepared geometry: PreparedGrain) -> [Float] {
        return [Float(value.amount),Float(1/(scale*geometry.fineSpacing)),Float(1/(scale*geometry.coarseSpacing)),
                Float(geometry.fineGain),Float(geometry.coarseGain),Float(value.chroma),
                Float(bitPattern:seed ^ (frameIndex &* 0x9e3779b9)),Float(originX),Float(originY),Float(geometry.subdivision(scale:scale))]
            + (envelope ?? PreparedResponseCurves.encode(value.luminanceCurve))
    }
}
