import XCTest
import ImagingCore
import ImageRendering
@testable import ImageAnalysis

final class GrainReferenceTests: XCTestCase {
    func testPreparationRejectsInvalidScaleParametersAndFootprint() throws {
        var grain = FilmGrain()
        XCTAssertThrowsError(try CameraEffectUniforms.grain(grain,scale:0,seed:1))
        XCTAssertThrowsError(try CameraEffectUniforms.grain(grain,scale:.infinity,seed:1))
        XCTAssertThrowsError(try GrainSamplingReference.sample(footprint:CGRect(x:0,y:0,width:4096,height:1),seed:1,parameters:grain))
        grain.size = .nan
        XCTAssertThrowsError(try GrainSamplingReference(parameters:grain))
        XCTAssertThrowsError(try CameraEffectUniforms.grain(grain,scale:1,seed:1))
    }

    func testReferenceAmountAndRadialHalfCorrelation() throws {
        var grain = FilmGrain()
        grain.amount = 0.02
        grain.chroma = 0
        var state: UInt64 = 43181
        func uniform() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / 9007199254740992
        }
        for size in [0.5,1,4,8] as [Double] {
            for roughness in [0,0.35,1] as [Double] {
                grain.size = size
                grain.roughness = roughness
                let reference = try GrainSamplingReference(parameters:grain)
                var sum = 0.0, squares = 0.0, lo = 0.0, hi = 0.0
                var fineVariance = 0.0, coarseVariance = 0.0
                let samples = 8192
                for i in 0..<samples {
                    let seed = UInt32(i%32)
                    let rect = CGRect(x:2048*uniform(),y:2048*uniform(),width:1,height:1)
                    let angle = 2*Double.pi*uniform(), dx = size*cos(angle), dy = size*sin(angle)
                    let (fine,coarse) = try reference.components(footprint:rect,seed:seed)
                    fineVariance += fine.x*fine.x
                    coarseVariance += coarse.x*coarse.x
                    let value = grain.amount*(fine.x+coarse.x)
                    let left = try reference.sample(footprint:rect.offsetBy(dx:0.9*dx,dy:0.9*dy),seed:seed).x
                    let right = try reference.sample(footprint:rect.offsetBy(dx:1.1*dx,dy:1.1*dy),seed:seed).x
                    sum += value
                    squares += value*value
                    lo += value*left
                    hi += value*right
                }
                let domain = "size=\(size), roughness=\(roughness)"
                XCTAssertEqual(sum/Double(samples),0,accuracy:0.001,domain)
                XCTAssertEqual(sqrt(squares/Double(samples)),grain.amount,accuracy:0.05*grain.amount,domain)
                XCTAssertEqual(coarseVariance/(fineVariance+coarseVariance),roughness,accuracy:0.025,domain)
                XCTAssertGreaterThan(lo/squares,0.5,domain)
                XCTAssertLessThan(hi/squares,0.5,domain)
            }
        }
    }

    func testPixelFootprintEqualsFourSubpixels() throws {
        var grain = FilmGrain()
        grain.amount = 0.02
        for size in [0.5, 1, 4, 8] as [Double] {
            for roughness in [0, 0.35, 1] as [Double] {
                grain.size = size
                grain.roughness = roughness
                let x = 123.25, y = 157.75
                let whole = try GrainSamplingReference.sample(footprint: CGRect(x:x,y:y,width:8,height:8), seed:42, parameters:grain)
                var sum = SIMD3<Double>.zero
                for j in 0...1 { for i in 0...1 {
                    sum += try GrainSamplingReference.sample(footprint:CGRect(x:x+Double(i*4),y:y+Double(j*4),width:4,height:4),seed:42,parameters:grain)
                }}
                for c in 0..<3 { XCTAssertEqual(whole[c], sum[c]/4, accuracy:1e-10) }
            }
        }
    }
}
