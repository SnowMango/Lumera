import ImagingCore

/// Immutable analytic function or point/tangent uniforms; no per-pixel CPU work.
public struct PreparedResponseCurves:Sendable {
    public let tone: [Float], grain: [Float], noise: [Float]
    init(_ p: StyleParameters) {
        tone = Self.encode(p.tone.curve)
        grain = Self.encode(p.grain.luminanceCurve)
        noise = Self.encode(p.noise.curve)
    }
    public static func encode(_ curve:ResponseCurve)->[Float] {
        if let f=curve.function {
            return [f.family.code,0,0,Float(f.xLower),Float(f.xUpper),Float(f.start),Float(f.end),Float(f.exponent),Float(f.center),Float(f.width)]
        }
        let k=curve.knots
        // Match CPU sampling for empty/singleton curves without indexing absent GPU knots.
        if k.count < 2 {
            let value = Float(k.first?.y ?? 0)
            return [CurveFamily.constant.code,0,0,0,1,value,value,2,0.5,0.25]
        }
        let m=ResponseCurve.tangents(k)
        return [0,curve.interpolation == .smooth ? 1:0,Float(k.count),0,1,0,0,0,0,0]+k.indices.flatMap{[Float(k[$0].x),Float(k[$0].y),Float(m[$0])]}
    }
}
