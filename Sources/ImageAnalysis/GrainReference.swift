import Foundation

/// Independent Double lattice reference for deterministic grain checks. No Metal,
/// production curve evaluator, uniforms or rendering helpers are used here.
enum GrainReference {
    static func value(x:Double,y:Double,seed:UInt32,roughness:Double)->Double {
        let fine=lattice(x:x,y:y,seed:seed)
        let coarse=lattice(x:x*0.4+13.7,y:y*0.4+29.1,seed:seed ^ 0xa341316c)
        let weights=[1-roughness,roughness]
        return (fine*weights[0]+coarse*weights[1])/sqrt(weights.reduce(0){$0+$1*$1})
    }
    private static func lattice(x:Double,y:Double,seed:UInt32)->Double {
        let ix=Int(floor(x)),iy=Int(floor(y)),fx=x-floor(x),fy=y-floor(y)
        let sx=fx*fx*(3-2*fx),sy=fy*fy*(3-2*fy)
        var total=0.0,variance=0.0
        for dy in 0...1 {for dx in 0...1 {
            let w=(dx==0 ? 1-sx:sx)*(dy==0 ? 1-sy:sy)
            let key=hash(UInt32(truncatingIfNeeded:ix+dx)) ^ hash(UInt32(truncatingIfNeeded:iy+dy) &+ 0x91e10da5) ^ seed
            let u=(Double(hash(key)>>8)+0.5)/16777216,v=(Double(hash(key ^ 0x9e3779b9)>>8)+0.5)/16777216
            total+=w*sqrt(-2*log(u))*cos(2 * Double.pi*v);variance+=w*w
        }}
        return total/sqrt(variance)
    }
    private static func hash(_ value:UInt32)->UInt32 {
        var x=value;x ^= x>>16;x=x &* 0x7feb352d;x ^= x>>15;x=x &* 0x846ca68b;return x ^ (x>>16)
    }
}
