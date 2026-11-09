import XCTest
import ImagingCore
import ImageRendering
@testable import ImageAnalysis

final class GenerationResourceIdentityTests: XCTestCase {
    func testChangedLUTPolicyRejectsMeasurementEvidence() throws {
        var lut = IndependentLUTCheck.cube { $0.map { $0 * 0.5 } }
        let old = GenerationResources(rendering: .init(lut: lut))
        let evidence = try old.validatedDigests()
        XCTAssertNoThrow(try old.validateEvidence(evidence))
        lut.boundaryPolicy = .extrapolate
        let changed = GenerationResources(rendering: .init(lut: lut))
        XCTAssertThrowsError(try changed.validateEvidence(evidence))
    }
    func testLegacyEvidenceWithoutProcessingIdentityIsRejected() throws {
        let resources = GenerationResources()
        XCTAssertThrowsError(try resources.validateEvidence([:]))
        XCTAssertNoThrow(try resources.validateEvidence(resources.validatedDigests()))
    }
    func testMalformedLUTCannotGenerateValidIdentity() throws {
        var lut = IndependentLUTCheck.cube { $0 }; lut.sha256 = "wrong"
        let resources = GenerationResources(rendering: .init(lut: lut))
        XCTAssertThrowsError(try resources.validatedDigests())
        XCTAssertThrowsError(try resources.validateEvidence(resources.digests))
        XCTAssertNil(resources.digests["processingIdentity.v1"])
    }
}
