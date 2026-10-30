import XCTest
@testable import ImagingCore
final class ResolvedStyleTests:XCTestCase {
    func testSameFinalSettingsHaveSameEffectiveDigest() throws {
        var p=StyleParameters();p.color.exposureEV=4
        let a=try ResolvedStyle(parameters:p,profileDigest:"a"),b=try ResolvedStyle(parameters:p,profileDigest:"b")
        XCTAssertEqual(a.effectiveDigest,b.effectiveDigest);XCTAssertEqual(a.parameters,p)
        p.color.exposureEV=1
        XCTAssertEqual(a.parameters.color.exposureEV,4)
        XCTAssertNotEqual(a.effectiveDigest,try ResolvedStyle(parameters:p).effectiveDigest)
    }
    func testInvalidFinalSettingsThrow() throws {
        var p=StyleParameters();p.color.exposureEV=7
        XCTAssertThrowsError(try ResolvedStyle(parameters:p))
        p.color.exposureEV = .nan;XCTAssertThrowsError(try ResolvedStyle(parameters:p))
    }
}
