import ImagingCore

/// Immutable analytic function or point/tangent uniforms; no per-pixel CPU work.
public struct PreparedResponseCurves:Sendable {
    public let tone:[Float],grain:[Float]
    init(_ p:StyleParameters) {tone=Self.encode(p.tone.curve);grain=Self.encode(p.grain.luminanceCurve)}
    public static func encode(_ curve:ResponseCurve)->[Float] {
        if let f=curve.function {
            return [f.family.code,0,0,Float(f.xLower),Float(f.xUpper),Float(f.start),Float(f.end),Float(f.exponent),Float(f.center),Float(f.width)]
        }
        let k=curve.knots,m=ResponseCurve.tangents(k)
        return [0,curve.interpolation == .smooth ? 1:0,Float(k.count),0,1,0,0,0,0,0]+k.indices.flatMap{[Float(k[$0].x),Float(k[$0].y),Float(m[$0])]}
    }
}
