import XCTest
@testable import ImagingCore

final class OptionalParameterValidationTests: XCTestCase {
    func testInterpolationUsesMatrixShapeWithoutCreativeRangeDiagnostics() throws {
        var a = ColorMatrix3x3(), b = ColorMatrix3x3()
        a.values[0] = 5; b.values[0] = 7
        XCTAssertThrowsError(try a.validate())
        let result = try ControlInterpolation.blend([.matrix(a), .matrix(b)], weights: [0.5, 0.5])
        guard case .matrix(let matrix) = result else { return XCTFail("Expected matrix") }
        XCTAssertEqual(matrix.values[0], 6)
        XCTAssertThrowsError(try ControlInterpolation.blend([.matrix(.init(values: [1])), .matrix(b)], weights: [0.5, 0.5]))
    }

    func testComputedWritesDoNotRevalidateUnchangedParameters() throws {
        var p = parameters, weights: [ResourceWeight] = []
        try ControlAccess.writeComputed(.scalar(1), target: "color.exposureEV", parameters: &p, lutWeights: &weights)
        XCTAssertEqual(p.color.exposureEV, 1)
        XCTAssertEqual(p.grain.roughness, 2)
        XCTAssertThrowsError(try p.validate())
    }

    private var parameters: StyleParameters {
        var value = StyleParameters()
        value.grain.enabled = false
        value.grain.roughness = 2
        value.detail.enabled = false
        value.detail.fineSigma = 3
        value.detail.midSigma = 1
        return value
    }

    func testLegacyExecutionDoesNotRequireParameterDiagnostics() throws {
        var profile = Profile.standard
        profile.parameters = parameters
        XCTAssertThrowsError(try profile.validate())
        let result = try StyleEvaluator.evaluate(StyleEvaluator.compile(profile)).resolvedStyle()
        XCTAssertEqual(result.parameters.grain.roughness, 2)
        XCTAssertFalse(result.parameters.grain.enabled)
        XCTAssertThrowsError(try result.parameters.validate(resolved: true))
    }

    func testSerializationAndIdentityDoNotInvokeParameterDiagnostics() throws {
        var profile = Profile.standard; profile.parameters = parameters
        let restored = try ProfileCodec.decode(ProfileCodec.encode(profile))
        XCTAssertEqual(restored.parameters.grain.roughness, 2)
        var model = StyleModel(identity: .init(id: "optional", name: "test"))
        model.appearance.parameters = parameters
        let decoded = try StyleModelCodec.decode(StyleModelCodec.encode(model))
        XCTAssertEqual(decoded.appearance.parameters.grain.roughness, 2)
        XCTAssertEqual(try decoded.digest(), try model.digest())
        XCTAssertThrowsError(try decoded.validate())
    }

    func testLegacyResponseHandlesInvalidLogarithmicCoordinatesAtSampling() throws {
        var profile = Profile.standard
        profile.responses = [.init(target: .grainSize, axis: .iso, operation: .replace,
            curve: .init(knots: [.init(x: -2, y: 1), .init(x: -1, y: 2)]))]
        let compiled = try StyleEvaluator.compile(profile)
        var conditions = CaptureConditions(); conditions.iso = 100
        XCTAssertThrowsError(try StyleEvaluator.evaluate(compiled, conditions: conditions))
    }

    func testModelDecisionAdaptationAndEditingDoNotScanUnusedParameters() throws {
        var definition = StyleModel(identity: .init(id: "optional-validation", name: "test"))
        definition.appearance.parameters = parameters
        definition.edits.strength = .init(neutralParameters: StyleParameters())
        XCTAssertThrowsError(try definition.validate())
        let model = try StyleModelCompiler.compile(definition)
        let stamp = FrameStamp(streamID: "test", generation: 0, index: 0, presentationTime: 0, duration: 1)
        let observations = FrameObservations(stamp: stamp, sourceID: "source", calibrationID: "calibration", featureDigest: model.featureDigest)
        let automatic = try StyleModelEvaluator.evaluate(model, context: .init(evaluationStamp: stamp, observations: observations))
        let adapted = try AdaptationReducer.reduce(automatic, state: nil, stamp: stamp, event: nil, policy: definition.adaptation)
        let unchanged = try EditResolver.resolve(.init(), automatic: adapted.controls, model: model)
        XCTAssertEqual(unchanged.parameters.grain.roughness, 2)
        XCTAssertEqual(unchanged.parameters.detail.midSigma, 1)
        var edits = EditRequest(); edits.strength = 1
        let edited = try EditResolver.resolve(edits, automatic: adapted.controls, model: model)
        XCTAssertEqual(edited.parameters.grain.roughness, 2)
        XCTAssertThrowsError(try edited.parameters.validate(resolved: true))
    }
}
