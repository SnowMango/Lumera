import XCTest
@testable import ImagingCore

final class StyleIdentityTests: XCTestCase {
    func testSchemaDefaultsEqualFullyWrittenParameters() throws {
        let minimal = Data(#"{"name":"demo","schemaVersion":8,"id":"a"}"#.utf8)
        var explicit = try ProfileCodec.decode(minimal)
        let encoded = try ProfileCodec.encode(explicit)
        XCTAssertEqual(try StyleIdentity.profile(explicit), try StyleIdentity.profile(ProfileCodec.decode(encoded)))
        let original = try StyleIdentity.profile(explicit)
        explicit.parameters.halation.radius = 5
        XCTAssertNotEqual(try StyleIdentity.profile(explicit), original)
    }

    func testCanonicalProfileAndEffectiveIdentities() throws {
        var p = Profile()
        let curve = ResponseCurve(knots: [.init(x:100,y:1), .init(x:400,y:2)])
        p.responses = [.init(target:.grainSize,axis:.iso,operation:.replace,curve:curve),
                       .init(target:.halationRadius,axis:.iso,operation:.replace,curve:curve)]
        var copy = p
        copy.id = "other"; copy.name = "Other"; copy.description = ""
        copy.responses.reverse()
        copy.parameters.color.exposureEV = -0.0
        XCTAssertEqual(try StyleIdentity.profile(copy), try StyleIdentity.profile(p))
        XCTAssertEqual(try ResolvedStyle(profile:copy).effectiveDigest, try ResolvedStyle(profile:p).effectiveDigest)
        copy.responses[0].curve.knots[1].y = 3
        XCTAssertNotEqual(try StyleIdentity.profile(copy), try StyleIdentity.profile(p))
        var c = CaptureConditions(); c.iso = 400
        let frozen = try StyleEvaluator.freeze(p, conditions:c)
        XCTAssertTrue(frozen.responses.isEmpty)
        XCTAssertEqual(frozen.name, p.name)
        XCTAssertEqual(frozen.id, p.id)
        XCTAssertEqual(frozen.parameters, try StyleEvaluator.evaluate(StyleEvaluator.compile(p), conditions:c).parameters)
    }
}
