import XCTest
import ImagingCore
@testable import ImageAnalysis

final class HalationReferenceTests: XCTestCase {
    func testContinuousRadiusAndSampledUnitMass() throws {
        for radius in [0.1,0.25,0.5,1,4,32] {
            let kernel = try HalationReference.kernel(radius:radius)
            var moment = 0.0
            for row in kernel.mixtures {
                XCTAssertEqual(row.reduce(0,+),1,accuracy:1e-14)
                for i in row.indices { moment += row[i] * 2 * pow(kernel.sigmas[i],2) / 3 }
            }
            XCTAssertEqual(sqrt(moment),radius,accuracy:1e-12)
            for resolution in EffectResolution.allCases {
                for component in kernel.sigmas.indices {
                    let weights = kernel.weights(component:component,pixelScale:resolution.scale)
                    XCTAssertTrue(weights.allSatisfy { $0 >= 0 })
                    XCTAssertEqual(weights.reduce(0,+),1,accuracy:1e-13)
                    XCTAssertEqual(weights,Array(weights.reversed()))
                }
            }
        }
        for invalid in [-1.0,0.0,33.0,.infinity,.nan] {
            XCTAssertThrowsError(try HalationReference.kernel(radius:invalid))
        }
    }
    func testSourceSubtractionAndFlatField() throws {
        let kernel = try HalationReference.kernel(radius:4)
        var point = [Double](repeating:0,count:65)
        point[32]=1
        let halo = kernel.residual(point,width:65,height:1,scaleX:1,scaleY:1)
        XCTAssertEqual(halo[32],.zero)
        XCTAssertGreaterThan(halo[45].x,halo[45].z)
        let field = kernel.residual(Array(repeating:0.8,count:65),width:65,height:1,scaleX:1,scaleY:1)
        XCTAssertTrue(field.allSatisfy { $0.max() < 1e-14 })
    }
}
