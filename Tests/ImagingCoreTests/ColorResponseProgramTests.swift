import XCTest
@testable import ImagingCore

final class ColorResponseProgramTests: XCTestCase {
    func curve(_ gain: Double) -> ResponseCurve { .init(knots: (0..<32).map { .init(x: Double($0)/31, y: Double($0)/31 * gain) }) }
    func matrix(_ gain: Double) -> ColorMatrix3x3 { .init(values: [gain,0,0,0,gain,0,0,0,gain]) }
    func model(_ target: String, _ values: [ControlValue]) -> StyleModel {
        var m = StyleModel(identity: .init(id: "typed", name: "test"))
        m.responses = [.init(target: target, expression: .singleAxis(axis: .target(.exposureBiasEV), nodes: [.init(0, values[0]), .init(1, values[1])], boundary: .clamp))]
        return m
    }
    func context(_ m: StyleModel, _ t: Double? = 0.5, time: Double = 0, index: UInt64 = 0) throws -> EvaluationContext {
        let stamp = FrameStamp(streamID: "typed", generation: 1, index: index, presentationTime: time, duration: 0.1)
        let o = FrameObservations(stamp: stamp, sourceID: "source", calibrationID: "cal", featureDigest: try m.observations.featureDigest())
        var target = CaptureConditions(); target.exposureBiasEV = t
        return .init(evaluationStamp: stamp, observations: o, targetConditions: target)
    }
    func resources(_ ids: [String]) -> [ModelResourceDescriptor] { ids.map { .init(id: $0, sha256: String(repeating: "a", count: 64), dimension: 2) } }
    func testMatrixAndCurveUseSameSingleAxisEvaluator() throws {
        let m = model("color.matrix", [.matrix(matrix(0.5)), .matrix(matrix(1))])
        XCTAssertEqual(try StyleModelEvaluator.evaluate(StyleModelCompiler.compile(m), context: context(m)).parameters.color.matrix, matrix(0.75))
        let c = model("tone.curve", [.curve(curve(0.5)), .curve(curve(1))])
        let result = try StyleModelEvaluator.evaluate(StyleModelCompiler.compile(c), context: context(c))
        for (actual, expected) in zip(result.parameters.tone.curve.knots, curve(0.75).knots) { XCTAssertEqual(actual.y, expected.y, accuracy: 1e-14) }
    }
    func testTwoAxisUsesFourCornersForCurvesAndLUTWeights() throws {
        for target in ["tone.curve", "style.lutWeights"] {
            var m = model(target, [.curve(curve(0)), .curve(curve(1))])
            m.appearance.resources = resources(["a", "b", "c", "d"])
            let values: [ControlValue] = target == "tone.curve" ? [0.25,0.5,0.75,1].map { .curve(curve($0)) } : ["a","b","c","d"].map { .resourceWeights([.init(resourceID: $0, weight: 1)]) }
            m.responses[0].expression = .twoAxisGrid(xAxis: .target(.exposureBiasEV), yAxis: .target(.iso), x: [0,1], y: [100,400], values: values, boundary: .clamp)
            var ctx = try context(m); ctx.targetConditions.iso = 200
            let result = try StyleModelEvaluator.evaluate(StyleModelCompiler.compile(m), context: ctx)
            if target == "tone.curve" { XCTAssertEqual(result.parameters.tone.curve.knots[31].y, 0.625, accuracy: 1e-14) }
            else { XCTAssertEqual(result.lutWeights.count, 4); for weight in result.lutWeights { XCTAssertEqual(weight.weight, 0.25, accuracy: 1e-14) } }
        }
    }
    func testNoncanonicalDynamicCurveRejectedWithoutApproximation() throws {
        var m = model("tone.curve", [.curve(.identity), .curve(curve(1))])
        XCTAssertThrowsError(try StyleModelCompiler.compile(m))
        var invalid = curve(1); invalid.knots[1].x += 0.001
        m = model("tone.curve", [.curve(invalid), .curve(curve(1))])
        XCTAssertThrowsError(try StyleModelCompiler.compile(m))
        m.responses[0].expression = .constant(.curve(.identity))
        XCTAssertNoThrow(try StyleModelCompiler.compile(m))
    }
    func testWeightPaletteAndDescriptorCompatibilityAreBounded() throws {
        var m = model("style.lutWeights", [.resourceWeights([.init(resourceID: "a", weight: 1)]), .resourceWeights([.init(resourceID: "b", weight: 1)])])
        m.appearance.resources = resources(["a","b"])
        XCTAssertNoThrow(try StyleModelCompiler.compile(m))
        m.appearance.resources[1].dimension = 3
        XCTAssertThrowsError(try StyleModelCompiler.compile(m))
        m.appearance.resources = resources(["a","b","c","d","e"])
        m.responses[0].expression = .singleAxis(axis: .target(.exposureBiasEV), nodes: ["a","b","c","d","e"].enumerated().map { .init(Double($0.offset), .resourceWeights([.init(resourceID: $0.element, weight: 1)])) }, boundary: .clamp)
        XCTAssertThrowsError(try StyleModelCompiler.compile(m))
    }
    func testTypedHoldPreservesOriginalStampAndRejectsForeignResource() throws {
        var m = model("style.lutWeights", [.resourceWeights([.init(resourceID: "a", weight: 1)]), .resourceWeights([.init(resourceID: "b", weight: 1)])])
        m.appearance.resources = resources(["a","b"]); m.responses[0].missing = .hold(maxAgeSeconds: 1)
        let compiled = try StyleModelCompiler.compile(m)
        let first = try StyleModelEvaluator.evaluate(compiled, context: context(m))
        var ctx = try context(m, nil, time: 0.5, index: 1); ctx.fallback = .init(controls: first, stamp: first.provenance[0].lastValidStamp!)
        let held = try StyleModelEvaluator.evaluate(compiled, context: ctx)
        XCTAssertEqual(held.lutWeights, first.lutWeights); XCTAssertEqual(held.provenance[0].lastValidStamp, first.provenance[0].lastValidStamp)
        ctx.fallback!.controls.lutWeights = []
        XCTAssertThrowsError(try StyleModelEvaluator.evaluate(compiled, context: ctx))
        ctx.fallback!.controls.lutWeights = [.init(resourceID: "foreign", weight: 1)]
        XCTAssertThrowsError(try StyleModelEvaluator.evaluate(compiled, context: ctx))
    }
    func testTypedTemporalResponseMatchesExponentialAndLocks() throws {
        for target in ["tone.curve", "color.matrix"] {
            let endpoints: [ControlValue] = target == "tone.curve" ? [.curve(curve(0)), .curve(curve(1))] : [.matrix(matrix(0)), .matrix(matrix(1))]
            let m = model(target, endpoints), compiled = try StyleModelCompiler.compile(m)
            let firstContext = try context(m, 0), secondContext = try context(m, 1, time: 1, index: 1)
            let first = try StyleModelEvaluator.evaluate(compiled, context: firstContext), second = try StyleModelEvaluator.evaluate(compiled, context: secondContext)
            var policy = AdaptationPolicy(); policy.rules = [.init(target: target, timeConstantSeconds: 1)]
            let state = try AdaptationReducer.reduce(first, state: nil, stamp: firstContext.evaluationStamp, event: nil, policy: policy)
            let result = try AdaptationReducer.reduce(second, state: state.state, stamp: secondContext.evaluationStamp, event: nil, policy: policy)
            let actual = target == "tone.curve" ? result.controls.parameters.tone.curve.knots[31].y : result.controls.parameters.color.matrix.values[0]
            XCTAssertEqual(actual, 1-exp(-1), accuracy: 1e-12)
            let locked = try AdaptationReducer.reduce(second, state: state.state, stamp: secondContext.evaluationStamp, event: .lock([.init(target: target, value: endpoints[0])]), policy: policy)
            XCTAssertEqual(try ControlAccess.value(target: target, parameters: locked.controls.parameters, lutWeights: locked.controls.lutWeights), endpoints[0])
        }
    }
    func testTemporalInitialPaletteCannotExceedFourResources() throws {
        let m = model("color.matrix", [.matrix(matrix(0)), .matrix(matrix(1))])
        let ctx = try context(m)
        var controls = try StyleModelEvaluator.evaluate(StyleModelCompiler.compile(m), context: ctx)
        controls.lutWeights = ["a", "b", "c", "d", "e"].map { .init(resourceID: $0, weight: 0.2) }
        var policy = AdaptationPolicy(); policy.rules = [.init(target: "style.lutWeights", timeConstantSeconds: 1)]
        XCTAssertThrowsError(try AdaptationReducer.reduce(controls, state: nil, stamp: ctx.evaluationStamp, event: nil, policy: policy))
    }

    func testDynamicWeightPoliciesMustHaveConvexEndpoints() throws {
        var m = model("style.lutWeights", [.resourceWeights([.init(resourceID: "a", weight: 1)]), .resourceWeights([.init(resourceID: "b", weight: 1)])])
        m.appearance.resources = resources(["a", "b"])
        var rule = AdaptationRule(target: "style.lutWeights", timeConstantSeconds: 1)
        rule.initialization = .constant(.resourceWeights([])); m.adaptation.rules = [rule]
        XCTAssertThrowsError(try StyleModelCompiler.compile(m))
        m.adaptation.rules = []
        m.edits.strength = .init(neutralParameters: .init(), neutralLUTWeights: [])
        XCTAssertThrowsError(try StyleModelCompiler.compile(m))
    }

    func testStaticTemporalEndpointsAreValidatedBeforeFirstFrame() throws {
        for hasConstantOwner in [false, true] {
            var m = model("tone.curve", [.curve(curve(0)), .curve(curve(1))])
            m.responses = hasConstantOwner ? [.init(target: "tone.curve", expression: .constant(.curve(.identity)))] : []
            var rule = AdaptationRule(target: "tone.curve", timeConstantSeconds: 1)
            rule.initialization = .constant(.curve(curve(0.5))); m.adaptation.rules = [rule]
            XCTAssertThrowsError(try StyleModelCompiler.compile(m))
        }
        var m = StyleModel(identity: .init(id: "static", name: "test"))
        m.appearance.resources = resources(["a"])
        var rule = AdaptationRule(target: "style.lutWeights", timeConstantSeconds: 1)
        rule.initialization = .constant(.resourceWeights([.init(resourceID: "a", weight: 1)])); m.adaptation.rules = [rule]
        XCTAssertThrowsError(try StyleModelCompiler.compile(m))
    }
    func testTemporalCurveEditsAndLocksRejectNoncanonicalEndpointsImmediately() throws {
        var m = model("tone.curve", [.curve(curve(0)), .curve(curve(1))])
        m.edits.overrideTargets = ["tone.curve"]
        m.adaptation.rules = [.init(target: "tone.curve", timeConstantSeconds: 1)]
        let compiled = try StyleModelCompiler.compile(m), ctx = try context(m)
        let automatic = try StyleModelEvaluator.evaluate(compiled, context: ctx)
        let edit = ControlOverride(target: "tone.curve", value: .curve(.identity))
        var request = EditRequest(); request.overrides = [edit]
        XCTAssertThrowsError(try EditResolver.resolve(request, automatic: automatic, model: compiled))
        XCTAssertThrowsError(try AdaptationReducer.reduce(automatic, state: nil, stamp: ctx.evaluationStamp, event: .lock([edit]), policy: m.adaptation))
    }
    func testEditablePaletteIncludesEverySelectableResource() throws {
        var m = StyleModel(identity: .init(id: "editable", name: "test"))
        m.appearance.resources = resources(["a", "b", "c", "d", "e"])
        m.appearance.lutWeights = [.init(resourceID: "a", weight: 1)]
        m.edits.overrideTargets = ["style.lutWeights"]
        XCTAssertThrowsError(try StyleModelCompiler.compile(m))
        m.appearance.resources = resources(["a", "b"]); m.appearance.resources[1].dimension = 3
        XCTAssertThrowsError(try StyleModelCompiler.compile(m))
    }

    func testTemporalWeightEditRejectsEmptyEndpointImmediately() throws {
        var m = model("style.lutWeights", [.resourceWeights([.init(resourceID: "a", weight: 1)]), .resourceWeights([.init(resourceID: "b", weight: 1)])])
        m.appearance.resources = resources(["a", "b"])
        m.edits.overrideTargets = ["style.lutWeights"]
        m.adaptation.rules = [.init(target: "style.lutWeights", timeConstantSeconds: 1)]
        let compiled = try StyleModelCompiler.compile(m)
        let automatic = try StyleModelEvaluator.evaluate(compiled, context: context(m))
        var edits = EditRequest(); edits.overrides = [.init(target: "style.lutWeights", value: .resourceWeights([]))]
        XCTAssertThrowsError(try EditResolver.resolve(edits, automatic: automatic, model: compiled))
    }

}
