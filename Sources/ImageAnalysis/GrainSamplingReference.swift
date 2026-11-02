import Foundation
import ImagingCore

/// Double reference in 2048-long-edge coordinates. Returns the encoded RGB perturbation
/// with a unit luminance-curve multiplier. No output clipping is applied.
public struct GrainSamplingReference {
    private let geometry: ReferenceCalibration
    private let grain: FilmGrain

    public init(parameters: FilmGrain) throws {
        var style = StyleParameters()
        style.grain = parameters
        try style.validate(resolved:true)
        geometry = ReferenceCalibration(size:parameters.size,roughness:parameters.roughness)
        grain = parameters
    }

    func rms(pixelWidth: Double) -> Double {
        grain.amount * geometry.relativeRMS(pixelWidth:pixelWidth)
    }

    public static func sample(footprint: CGRect, seed: UInt32, parameters: FilmGrain) throws -> SIMD3<Double> {
        try Self(parameters:parameters).sample(footprint:footprint,seed:seed)
    }

    public func sample(footprint: CGRect, seed: UInt32) throws -> SIMD3<Double> {
        let (fine,coarse) = try components(footprint:footprint,seed:seed)
        let v = fine + coarse
        let cb = v.y * grain.chroma, cr = v.z * grain.chroma
        return SIMD3(v.x+1.5748*cr,v.x-0.187324*cb-0.468124*cr,v.x+1.8556*cb) * grain.amount
    }

    func components(footprint: CGRect, seed: UInt32) throws -> (SIMD3<Double>,SIMD3<Double>) {
        guard footprint.size.width > 0, footprint.size.height > 0,
              footprint.width <= 2048, footprint.height <= 2048,
              [footprint.minX,footprint.maxX,footprint.minY,footprint.maxY].allSatisfy({$0.isFinite && abs($0) < 1e8}) else {
            throw LabError.invalid("颗粒积分区域无效")
        }
        func layer(_ spacing: Double, _ gain: Double, _ salt: UInt32) -> SIMD3<Double> {
            guard gain > 0 else { return .zero }
            let xs = Self.weights(footprint.minX/spacing,footprint.maxX/spacing)
            let ys = Self.weights(footprint.minY/spacing,footprint.maxY/spacing)
            var sum = SIMD3<Double>.zero
            func addSites(_ columns: ArraySlice<(Int,Double)>, _ rows: ArraySlice<(Int,Double)>) {
                for (j,wy) in rows { for (i,wx) in columns {
                    let w = wx * wy
                    let key = Self.blockKey(x:i,y:j,seed:seed ^ salt)
                    let index = UInt32((j & 15)*16 + (i & 15))
                    sum.x += w * Self.coefficient(key,index)
                    if grain.chroma > 0 {
                        sum.y += w * Self.coefficient(key ^ 0x68bc21eb,index)
                        sum.z += w * Self.coefficient(key ^ 0x02e5be93,index)
                    }
                }}
            }
            if xs.count*ys.count < 65536 {
                addSites(xs[...],ys[...])
            } else {
                // The small-footprint oracle above visits each site. For very large
                // integrals, every fully covered block has the same weight at all sites.
                let normalized = spacing*spacing/(footprint.width*footprint.height)
                let columns = Self.blocks(xs), rows = Self.blocks(ys)
                for yy in rows { for xx in columns {
                    let i = xx.first!.0, j = yy.first!.0
                    if xx.count == 16, yy.count == 16,
                       Double(i-2) >= footprint.minX/spacing, Double(j-2) >= footprint.minY/spacing,
                       Double(i+17) <= footprint.maxX/spacing, Double(j+17) <= footprint.maxY/spacing {
                        let key = Self.blockKey(x:i,y:j,seed:seed ^ salt)
                        sum.x += normalized*Self.blockSum(key)
                        if grain.chroma > 0 {
                            sum.y += normalized*Self.blockSum(key ^ 0x68bc21eb)
                            sum.z += normalized*Self.blockSum(key ^ 0x02e5be93)
                        }
                    } else { addSites(xx,yy) }
                }}
            }
            return sum * gain
        }
        return (layer(geometry.fineSpacing,geometry.fineGain,0),
                layer(geometry.coarseSpacing,geometry.coarseGain,0xa341316c))
    }

    private static func blocks(_ axis: [(Int,Double)]) -> [ArraySlice<(Int,Double)>] {
        var result = [ArraySlice<(Int,Double)>](), start = 0
        while start < axis.count {
            let end = min(axis.count,start+16-(axis[start].0 & 15))
            result.append(axis[start..<end])
            start = end
        }
        return result
    }

    private static func weights(_ a: Double, _ b: Double) -> [(Int,Double)] {
        // Integrate piecewise cubic using two-point Gauss-Legendre on each knot interval.
        func basis(_ x: Double) -> Double {
            let t = abs(x)
            if t >= 2 { return 0 }
            if t >= 1 { return pow(2-t,3)/6 }
            return (4-6*t*t+3*t*t*t)/6
        }
        return (Int(floor(a))-1...Int(ceil(b))+1).map { i in
            var integral = 0.0
            for k in -2..<2 {
                let lo = max(a-Double(i),Double(k)), hi = min(b-Double(i),Double(k+1))
                if lo < hi {
                    let h = (hi-lo)/2, mid = (hi+lo)/2, offset = h / sqrt(3)
                    integral += h * (basis(mid-offset)+basis(mid+offset))
                }
            }
            return (i,integral/(b-a))
        }
    }

    private static func blockKey(x:Int,y:Int,seed:UInt32) -> UInt32 {
        hash(UInt32(truncatingIfNeeded:x >> 4)) ^ hash(UInt32(truncatingIfNeeded:y >> 4) &+ 0x91e10da5) ^ seed
    }
    private static func blockMean(_ key: UInt32) -> Double {
        ((Double(hash(key ^ 0x149b1aad)>>8)+0.5)/16777216-0.5)*sqrt(12/257)
    }
    private static func blockSum(_ key: UInt32) -> Double {
        257 * blockMean(key) - coefficient(key,256)
    }
    private static func coefficient(_ key: UInt32, _ index: UInt32) -> Double {
        let permutation = hash(key)
        let a = 1+(permutation & 255), b = (permutation>>8)%257
        let u = (a*index+b)%257
        let entry = Double((u*u*u)%257)-128
        return blockMean(key) + entry * sqrt(256.0/257/5504)
    }
    private static func hash(_ value:UInt32)->UInt32 {
        var x=value;x ^= x>>16;x=x &* 0x7feb352d;x ^= x>>15;x=x &* 0x846ca68b;return x ^ (x>>16)
    }
}

extension GrainSamplingReference {
    /// Efficient separable evaluation of the same Double reference over a regular square grid.
    /// Used to generate monochrome synthetic captures independently of the Metal renderer.
    func luminancePlane(side: Int, pixelWidth: Double, seed: UInt32) -> [Double] {
        var result = [Double](repeating:0,count:side*side)
        for (spacing,gain,salt) in [(geometry.fineSpacing,geometry.fineGain,UInt32(0)),
                                      (geometry.coarseSpacing,geometry.coarseGain,UInt32(0xa341316c))] where gain > 0 {
            let width = pixelWidth / spacing
            let axes = (0..<side).map { Self.weights(Double($0)*width,Double($0+1)*width) }
            let first = axes[0][0].0, last = axes[side-1].last!.0
            var rows = [Double](repeating:0,count:(last-first+1)*side)
            for j in first...last {
                let row = (first...last).map { i in
                    Self.coefficient(Self.blockKey(x:i,y:j,seed:seed ^ salt),UInt32((j & 15)*16+(i & 15)))
                }
                for x in axes.indices {
                    rows[(j-first)*side+x] = axes[x].reduce(0){$0 + row[$1.0-first] * $1.1}
                }
            }
            for y in axes.indices { for (j,w) in axes[y] {
                let factor = w * gain * grain.amount
                for x in axes.indices { result[y*side+x] += rows[(j-first)*side+x] * factor }
            }}
        }
        return result
    }
}


// Independent covariance oracle. The autocorrelation of a cubic B-spline is the
// centered degree-seven spline. Two box integrations take its second antiderivative
// at three endpoints. Reflection keeps all truncated powers on the stable left half.
private struct ReferenceCalibration {
    let fineSpacing, coarseSpacing, fineGain, coarseGain: Double

    private static func primitive(_ x: Double) -> Double {
        let t = 4 - abs(x)
        let coefficients = [1.0,-8,28,-56,70]
        var left = 0.0
        for i in coefficients.indices where t > Double(i) {
            let u = t-Double(i), u2 = u*u, u4 = u2*u2
            left += coefficients[i]*u4*u4*u
        }
        return max(0,x) + left/362880
    }

    private static func covariance(_ lag: Double, _ spacing: Double, pixelWidth: Double = 1) -> Double {
        let d = lag/spacing, width = pixelWidth/spacing
        return (primitive(d+width)-2*primitive(d)+primitive(d-width))/(width*width)
    }

    private static func radial(_ size: Double, _ spacing: Double) -> Double {
        let variance = pow(covariance(0,spacing),2)
        var result = 0.0
        for i in 0..<12 {
            let angle = (Double(i)+0.5)*Double.pi/48
            result += covariance(size*cos(angle),spacing)*covariance(size*sin(angle),spacing)
        }
        return result/(12*variance)
    }

    init(size: Double, roughness: Double) {
        var lo = 0.01, hi = 2*size
        for _ in 0..<36 {
            let mid = (lo+hi)/2
            let c = (1-roughness)*Self.radial(size,mid) + roughness*Self.radial(size,2.5*mid)
            if c < 0.5 { lo = mid } else { hi = mid }
        }
        fineSpacing = (lo+hi)/2
        coarseSpacing = 2.5*fineSpacing
        fineGain = sqrt(1-roughness)/Self.covariance(0,fineSpacing)
        coarseGain = sqrt(roughness)/Self.covariance(0,coarseSpacing)
    }

    func relativeRMS(pixelWidth: Double) -> Double {
        hypot(fineGain*Self.covariance(0,fineSpacing,pixelWidth:pixelWidth),
              coarseGain*Self.covariance(0,coarseSpacing,pixelWidth:pixelWidth))
    }
}
