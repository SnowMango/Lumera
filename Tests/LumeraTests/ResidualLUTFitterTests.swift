import XCTest
import Foundation
import ImagingCore
@testable import ImageAnalysis

final class ResidualLUTFitterTests: XCTestCase {
    func testSparseNonlinearResidualGeneralizesToIndependentColors() throws {
        func target(_ x:[Double])->[Double] { [x[0]+0.08*x[0]*(1-x[0])*x[1],x[1],x[2]-0.06*x[2]*(1-x[2])*x[0]] }
        var samples=[ResidualLUTFitter.Sample]()
        for r in 0...8 { for g in 0...8 { for b in 0...8 {
            let x=[Double(r)/8,Double(g)/8,Double(b)/8]
            samples.append(.init(input:x,target:target(x)))
        } } }
        let fit = try ResidualLUTFitter.fit(samples:samples,tone:.identity,dimension:17,regularization:0.001,maxIterations:200,tolerance:1e-7)
        for r in 0..<8 { for g in 0..<8 { for b in 0..<8 {
            let x=[(Double(r)+0.43)/8,(Double(g)+0.57)/8,(Double(b)+0.31)/8]
            for (a,y) in zip(try fit.grid.sample(x),target(x)) { XCTAssertLessThanOrEqual(abs(a-y),0.01) }
        } } }
    }
    func testIdentityAndBoundsAreExplicit() throws {
        let identity = try LUTSampleGrid.identity(dimension:17)
        let x=[0.17,0.36,0.81]
        for (a,b) in zip(try identity.sample(x),x) { XCTAssertEqual(a,b,accuracy:1e-6) }
        XCTAssertThrowsError(try ResidualLUTFitter.fit(samples:[],tone:.identity,dimension:17))
        XCTAssertThrowsError(try LUTSampleGrid(dimension:17,samples:[0,0,0]))
    }
}
