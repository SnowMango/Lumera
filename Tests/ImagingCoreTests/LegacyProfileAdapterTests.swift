import XCTest
@testable import ImagingCore

final class LegacyProfileAdapterTests: XCTestCase {
    func testLegacyTemporalPolicyCannotBeReplacedByUnrelatedAppearancePolicy() throws {
        let profile = Profile()
        var model = try LegacyProfileAdapter.adapt(profile)
        model.appearance.temporalPolicy.grain = .fixed
        XCTAssertEqual(try CameraModelCompiler.compile(model).temporalPolicy, profile.temporalPolicy)
    }
    func testLegacyParametersConditionsTemporalPolicyAndLUTSemantics() throws {
        var profile = Profile(); profile.parameters.color.exposureEV = 99
        profile.parameters.color.whiteBalance.destination = .init(x: 0.35, y: 0.36)
        profile.parameters.grain.enabled = true
        profile.responses = [.init(target: .grainAmount, axis: .iso, operation: .replace, curve: .init(knots: [.init(x: 100, y: 0.01), .init(x: 400, y: 0.03)]))]
        let model = try LegacyProfileAdapter.adapt(profile)
        let compiled = try CameraModelCompiler.compile(model)
        XCTAssertEqual(model.legacyProfile, profile)
        XCTAssertTrue(model.appearance.resources.isEmpty)
        XCTAssertTrue(model.appearance.lutWeights.isEmpty)
        for iso in [nil, 200.0, 800.0] as [Double?] {
            let stamp = FrameStamp(streamID: "legacy", generation: 1, index: 7, presentationTime: 0.7, duration: 0.1)
            var observation = FrameObservations(stamp: stamp, sourceID: "source", calibrationID: "calibration", featureDigest: try model.observations.featureDigest())
            observation.captureConditions.iso = iso
            let result = try CameraModelEvaluator.evaluate(compiled, context: .init(evaluationStamp: stamp, observations: observation))
            let expected = try StyleEvaluator.evaluate(StyleEvaluator.compile(profile), conditions: observation.captureConditions)
            XCTAssertEqual(result.parameters, expected.parameters)
            XCTAssertEqual(compiled.temporalPolicy, expected.temporalPolicy)
            for frame: UInt32 in [0, 7, .max] {
                XCTAssertEqual(compiled.temporalPolicy.grain.seed(42, frameIndex: frame), expected.temporalPolicy.grain.seed(42, frameIndex: frame))
                XCTAssertEqual(compiled.temporalPolicy.noise.seed(42, frameIndex: frame), expected.temporalPolicy.noise.seed(42, frameIndex: frame))
            }
        }
    }
}
