import XCTest
@testable import ImageRendering
final class GaussianKernelTests:XCTestCase {
    func testRejectsInvalidKernelScales() {
        for sigma:Float in [0,-1,.nan,.infinity,257] {XCTAssertThrowsError(try PreparedGaussianKernel(sigma:sigma,noise:false))}
    }
    func testOpticalWeightsPreserveConstantAndImpulseShape() throws {
        let kernel=try PreparedGaussianKernel(sigma:1,noise:false)
        XCTAssertEqual(kernel.radius,3)
        let expected:[Float]=[0.004433048,0.05400558,0.24203623,0.39905028,0.24203623,0.05400558,0.004433048]
        XCTAssertEqual(kernel.weights.count,expected.count)
        for (a,b) in zip(kernel.weights,expected){XCTAssertEqual(a/kernel.denominator,b,accuracy:0.000001)}
        XCTAssertEqual(kernel.weights.reduce(0,+)/kernel.denominator,1,accuracy:0.000001)
    }
    func testNoiseWeightsPreserveVarianceRatherThanMean() throws {
        let kernel=try PreparedGaussianKernel(sigma:1,noise:true)
        let variance=kernel.weights.map{($0/kernel.denominator)*($0/kernel.denominator)}.reduce(0,+)
        XCTAssertEqual(variance,1,accuracy:0.000001)
    }
}
