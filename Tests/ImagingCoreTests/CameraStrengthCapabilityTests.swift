import XCTest
@testable import ImagingCore

final class CameraStrengthCapabilityTests: XCTestCase {
    func testCompilerRejectsAdvertisedUnrepresentableStrength() throws {
        var model = CameraModel(identity: .init(id: "fixture", camera: "synthetic", mode: "neutral"))
        model.appearance.parameters.tone.enabled = true
        model.appearance.parameters.tone.curve = .init(function: .init(family: .power))
        model.edits.strength = .init(neutralParameters: .init())
        XCTAssertThrowsError(try CameraModelCompiler.compile(model))
    }
}
