import XCTest
import ImagingCore
@testable import ImageAnalysis
final class GlowSolverTests:XCTestCase {
    func testIndependentLightMeasurementAndRecovery()throws {
        let measured=try GlowDeveloperCheck.run()
        XCTAssertLessThanOrEqual(try XCTUnwrap(measured["radialResponse"]),0.01)
        XCTAssertEqual(measured["rejectAmbiguousGlow"],0)
        XCTAssertLessThanOrEqual(try XCTUnwrap(measured["rgbReduction"]),0.000001)
    }
    func testExistingBaselineCannotRegressOnHeldOutLight() throws {
        let f=try GlowDeveloperCheck.fixture(trainingGlow:0.28);defer{f.cleanup()}
        var p=f.baseline;p.parameters.glow.enabled=true;p.parameters.glow.amount=0.25;p.parameters.halation.enabled=true;p.parameters.halation.amount=0.35
        XCTAssertThrowsError(try GlowSolver.solve(measurements:f.bundle,baseline:p,options:.init(model:.film,modules:[.glow],baseline:p),resources:.init())) { error in
            XCTAssertTrue(error.localizedDescription.contains("退化"),error.localizedDescription)
        }
    }
    func testCannotValidateLuminanceOnlyOrMissingFiles()throws {
        XCTAssertThrowsError(try GlowSolver.solve(measurements:.init(frames:[],resourceDigests:[:]),baseline:.standard,options:.init(model:.film,modules:[.glow],baseline:.standard),resources:.init()))
    }
}
