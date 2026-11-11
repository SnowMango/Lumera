import XCTest
@testable import ImagingCore

final class StyleStrengthCapabilityTests: XCTestCase {
    func testCompilerRejectsAdvertisedUnrepresentableStrength() throws {
        var model = StyleModel(identity: .init(id: "fixture", name: "neutral"))
        model.appearance.parameters.tone.enabled = true
        model.appearance.parameters.tone.curve = .init(function: .init(family: .power))
        model.edits.strength = .init(neutralParameters: .init())
        XCTAssertThrowsError(try StyleModelCompiler.compile(model))
    }
}
