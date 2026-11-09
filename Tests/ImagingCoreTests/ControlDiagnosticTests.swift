import XCTest
@testable import ImagingCore

final class ControlDiagnosticTests: XCTestCase {
    func testMissingObservationHasStableCodeAndTarget() throws {
        var definition = CameraModel(identity: .init(id: "fixture", camera: "synthetic", mode: "neutral"))
        definition.responses = [.init(target: "glow.amount", expression: .singleAxis(axis: .target(.iso),
            nodes: [.init(100, .scalar(0)), .init(800, .scalar(1))], boundary: .clamp), missing: .constant(.scalar(0.2)))]
        let model = try CameraModelCompiler.compile(definition)
        let stamp = FrameStamp(streamID: "test", generation: 0, index: 0, presentationTime: 0, duration: 1)
        let observations = FrameObservations(stamp: stamp, sourceID: "source", calibrationID: "calibration", featureDigest: model.featureDigest)
        let result = try CameraModelEvaluator.evaluate(model, context: .init(evaluationStamp: stamp, observations: observations))
        let diagnostic = try XCTUnwrap(result.diagnostics.first)
        XCTAssertEqual(diagnostic.code, .missingObservation)
        XCTAssertEqual(diagnostic.target, "glow.amount")
        XCTAssertEqual(try JSONDecoder().decode(AutomaticControls.self, from: JSON.encode(result)), result)
    }
}
