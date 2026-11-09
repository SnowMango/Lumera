import XCTest
import ImagingCore
@testable import ImageRendering

final class RenderResourceIdentityTests: XCTestCase {
    func testIdentityTracksPolicyAndRoleButNotName() throws {
        let asset = IndependentLUTTests.asset(0.5)
        let original = try RenderResourceIdentity(resources: .init(lut: asset))
        var changed = asset; changed.name = "renamed"
        XCTAssertEqual(original, try RenderResourceIdentity(resources: .init(lut: changed)))
        changed.boundaryPolicy = .extrapolate
        XCTAssertNotEqual(try original.digest(), try RenderResourceIdentity(resources: .init(lut: changed)).digest())
        XCTAssertNotEqual(original, try RenderResourceIdentity(resources: .init(correctionLUT: asset)))
        XCTAssertNotEqual(original, try RenderResourceIdentity(resources: .init(lut: IndependentLUTTests.asset(0.25))))
        XCTAssertEqual(try RenderResourceIdentity(resources: .init()).digest(), try RenderResourceIdentity(resources: .init()).digest())
        changed.sha256 = "invalid"
        XCTAssertThrowsError(try RenderResourceIdentity(resources: .init(lut: changed)))
    }
    func testLegacyRenderIdentityEncodingIsPreserved() throws {
        let style = try ResolvedStyle(profile: .standard)
        var request = RenderRequest(input: InputDescriptor(width: 17, height: 13))
        var lut = IndependentLUTTests.asset(0.5)
        XCTAssertEqual("ab3e7d3e053d483a471de8cdbeb1ab1de6ce2a25c90175d59376db331f78fe57", try RenderIdentity.make(style: style, request: request, precision: .float32))
        lut.boundaryPolicy = .extrapolate
        XCTAssertEqual("2ae9cf1f830b0cda579fcf28adcfadbf1b4726456e153ebe98d65fba7009b1d1", try RenderIdentity.make(style: style, resources: .init(lut: lut), request: request, precision: .float32))
        request.dynamicRange = .edr
        XCTAssertEqual("ee5395ee68758692aab63e110176039036068782586b3a4a70fdc909647eae4f", try RenderIdentity.make(style: style, resources: .init(lut: lut), request: request, precision: .float32))
    }
}
