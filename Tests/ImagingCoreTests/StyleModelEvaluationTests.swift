import XCTest
@testable import ImagingCore

final class StyleModelEvaluationTests: XCTestCase {
    func model(_ value: Double = 0.5) -> StyleModel {
        var m = StyleModel(identity: .init(id: "test", name: "test"))
        m.observations.features = [.init(id: "mean", statistic: .meanGreen)]
        m.responses = [.init(target: "glow.amount", expression: .singleAxis(axis: .feature("mean"), nodes: [.init(0, .scalar(0)), .init(1, .scalar(value))], boundary: .clamp))]
        return m
    }
    func stamp(_ time: Double = 0, _ index: UInt64 = 0) -> FrameStamp {
        .init(streamID: "stream", generation: 1, index: index, presentationTime: time, duration: 0.1)
    }
    func context(_ m: StyleModel, value: Double? = 0.5, time: Double = 0, index: UInt64 = 0) throws -> EvaluationContext {
        var o = FrameObservations(stamp: stamp(time, index), sourceID: "source-digest", calibrationID: "calibration-digest", featureDigest: try m.observations.featureDigest())
        o.features = [.init(id: "mean", value: value)]
        return .init(evaluationStamp: o.stamp, observations: o)
    }
    func testSameObservationDifferentModels() throws {
        let a = model(0.5)
        var b = model(1); b.responses[0].expression = .singleAxis(axis: .feature("mean"), nodes: [.init(0, .scalar(0.5)), .init(1, .scalar(1))], boundary: .clamp)
        let ctx = try context(a)
        XCTAssertEqual(try StyleModelEvaluator.evaluate(StyleModelCompiler.compile(a), context: ctx).parameters.glow.amount, 0.25)
        XCTAssertEqual(try StyleModelEvaluator.evaluate(StyleModelCompiler.compile(b), context: ctx).parameters.glow.amount, 0.75)
        XCTAssertNotEqual(try StyleModelCompiler.compile(a).modelDigest, try StyleModelCompiler.compile(b).modelDigest)
    }
    func testTwoAxisBilinearAndBoundaryPolicy() throws {
        var m = model()
        m.responses[0].expression = .twoAxisGrid(xAxis: .feature("mean"), yAxis: .target(.exposureBiasEV), x: [0, 1], y: [0, 1], values: [0, 1, 1, 0].map { .scalar($0) }, boundary: .clamp)
        var ctx = try context(m); ctx.targetConditions.exposureBiasEV = 0.5
        XCTAssertEqual(try StyleModelEvaluator.evaluate(StyleModelCompiler.compile(m), context: ctx).parameters.glow.amount, 0.5, accuracy: 1e-12)
        ctx.targetConditions.exposureBiasEV = 2; ctx.observations.features[0].value = 0
        XCTAssertEqual(try StyleModelEvaluator.evaluate(StyleModelCompiler.compile(m), context: ctx).parameters.glow.amount, 1)
        m.responses[0].expression = .singleAxis(axis: .feature("mean"), nodes: [.init(0, .scalar(0)), .init(1, .scalar(1))], boundary: .reject)
        ctx.observations.features[0].value = 2
        XCTAssertThrowsError(try StyleModelEvaluator.evaluate(StyleModelCompiler.compile(m), context: ctx))
    }
    func testMissingFeatureAndSourceISODoNotInventTarget() throws {
        var m = model(); m.responses[0].expression = .singleAxis(axis: .target(.iso), nodes: [.init(100, .scalar(0)), .init(400, .scalar(1))], boundary: .clamp)
        m.responses[0].missing = .constant(.scalar(0.1))
        var ctx = try context(m); ctx.observations.captureConditions.iso = 200
        XCTAssertEqual(try StyleModelEvaluator.evaluate(StyleModelCompiler.compile(m), context: ctx).parameters.glow.amount, 0.1)
        ctx.targetConditions.iso = 200
        XCTAssertEqual(try StyleModelEvaluator.evaluate(StyleModelCompiler.compile(m), context: ctx).parameters.glow.amount, 0.5, accuracy: 1e-12)
        m = model(); ctx = try context(m, value: nil)
        XCTAssertThrowsError(try StyleModelEvaluator.evaluate(StyleModelCompiler.compile(m), context: ctx))
    }
    func testHoldPreservesOriginalValidityAndRejectsIdentityChanges() throws {
        var m = model(); m.responses[0].missing = .hold(maxAgeSeconds: 1)
        let compiled = try StyleModelCompiler.compile(m)
        let first = try StyleModelEvaluator.evaluate(compiled, context: context(m))
        var ctx = try context(m, value: nil, time: 0.5, index: 5)
        XCTAssertThrowsError(try StyleModelEvaluator.evaluate(compiled, context: ctx))
        ctx.fallback = .init(controls: first, stamp: stamp())
        let held = try StyleModelEvaluator.evaluate(compiled, context: ctx)
        XCTAssertEqual(held.provenance.first?.lastValidStamp, stamp())
        XCTAssertEqual(held.provenance.first?.isFallback, true)
        ctx = try context(m, value: nil, time: 1.1, index: 11); ctx.fallback = .init(controls: held, stamp: stamp(0.5, 5))
        XCTAssertThrowsError(try StyleModelEvaluator.evaluate(compiled, context: ctx))
        for key in ["model", "source", "calibration", "feature", "stream", "generation"] {
            ctx = try context(m, value: nil, time: 0.5, index: 5); ctx.fallback = .init(controls: first, stamp: stamp())
            switch key {
            case "model": ctx.fallback!.controls.modelID = "changed"
            case "source": ctx.fallback!.controls.sourceID = "changed"
            case "calibration": ctx.fallback!.controls.calibrationID = "changed"
            case "feature": ctx.fallback!.controls.featureDigest = "changed"
            case "stream": ctx.fallback!.stamp.streamID = "changed"
            default: ctx.fallback!.stamp.generation += 1
            }
            XCTAssertThrowsError(try StyleModelEvaluator.evaluate(compiled, context: ctx), key)
        }
    }
    func testConstantFallbackDoesNotInventOrRefreshValidity() throws {
        var m = model(); m.responses[0].missing = .constant(.scalar(0.1))
        let compiled = try StyleModelCompiler.compile(m)
        let missing = try StyleModelEvaluator.evaluate(compiled, context: context(m, value: nil))
        XCTAssertNil(missing.provenance.first?.lastValidStamp)
        let valid = try StyleModelEvaluator.evaluate(compiled, context: context(m))
        var ctx = try context(m, value: nil, time: 0.5, index: 5)
        ctx.fallback = .init(controls: valid, stamp: stamp())
        let first = try StyleModelEvaluator.evaluate(compiled, context: ctx)
        XCTAssertEqual(first.provenance.first?.lastValidStamp, stamp())
        ctx = try context(m, value: nil, time: 1, index: 10)
        ctx.fallback = .init(controls: first, stamp: stamp(0.5, 5))
        XCTAssertEqual(try StyleModelEvaluator.evaluate(compiled, context: ctx).provenance.first?.lastValidStamp, stamp())
        ctx.fallback!.controls.modelID = "another revision"
        XCTAssertNil(try StyleModelEvaluator.evaluate(compiled, context: ctx).provenance.first?.lastValidStamp)
    }
    func testTargetCompatibilityRequiresExplicitInRangeConditions() throws {
        var m = model(); m.compatibility.targetConditions = [.init(axis: .iso, bounds: .init(lower: 100, upper: 400))]
        let compiled = try StyleModelCompiler.compile(m)
        var ctx = try context(m); ctx.observations.captureConditions.iso = 200
        XCTAssertThrowsError(try StyleModelEvaluator.evaluate(compiled, context: ctx))
        ctx.targetConditions.iso = 800
        XCTAssertThrowsError(try StyleModelEvaluator.evaluate(compiled, context: ctx))
        ctx.targetConditions.iso = 200
        XCTAssertNoThrow(try StyleModelEvaluator.evaluate(compiled, context: ctx))
    }
    func testMalformedHistoryIsRejectedBeforeReadingControls() throws {
        var m = model(); m.responses[0].missing = .hold(maxAgeSeconds: 1)
        let compiled = try StyleModelCompiler.compile(m)
        var previous = try StyleModelEvaluator.evaluate(compiled, context: context(m))
        previous.parameters.color.matrix.values = []
        var ctx = try context(m, value: nil, time: 0.1, index: 1)
        ctx.fallback = .init(controls: previous, stamp: stamp())
        XCTAssertThrowsError(try StyleModelEvaluator.evaluate(compiled, context: ctx))
    }
    func testDelayedPacketRequiresDeclaredAgeAndIdentity() throws {
        var m = model(); var ctx = try context(m)
        ctx.evaluationStamp = stamp(0.1, 1)
        XCTAssertThrowsError(try StyleModelEvaluator.evaluate(StyleModelCompiler.compile(m), context: ctx))
        m.observations.validity.maxAgeSeconds = 0.2; m.observations.validity.maxAgeFrames = 2
        let result = try StyleModelEvaluator.evaluate(StyleModelCompiler.compile(m), context: ctx)
        XCTAssertEqual(result.provenance.first?.lastValidStamp, stamp())
        ctx.observations.featureDigest = "wrong"
        XCTAssertThrowsError(try StyleModelEvaluator.evaluate(StyleModelCompiler.compile(m), context: ctx))
    }
    func testDuplicateOwnersAndCyclesRejected() throws {
        var m = model(); m.responses.append(m.responses[0])
        XCTAssertThrowsError(try StyleModelCompiler.compile(m))
        // The closed grammar has no control-reference expression; decoding one must fail.
        XCTAssertThrowsError(try JSONDecoder().decode(ResponseExpression.self, from: Data(#"{"control":{"_0":"glow.amount"}}"#.utf8)))
    }
    func testCrossParameterExtremaRejected() throws {
        var m = model(); m.responses = [.init(target: "detail.fineSigma", expression: .constant(.scalar(8)))]
        XCTAssertThrowsError(try StyleModelCompiler.compile(m))
        m.responses = [.init(target: "color.whiteBalance.source.x", expression: .constant(.scalar(0.7)))]
        XCTAssertThrowsError(try StyleModelCompiler.compile(m))
    }
    func testNoncanonicalDynamicCurvesRejectedAndStaticBlocksWork() throws {
        var m = model(); m.responses = [.init(target: "tone.curve", expression: .singleAxis(axis: .feature("mean"), nodes: [.init(0, .curve(.identity)), .init(1, .curve(.identity))], boundary: .clamp))]
        XCTAssertThrowsError(try StyleModelCompiler.compile(m))
        m.responses[0].expression = .constant(.curve(.identity))
        XCTAssertEqual(try StyleModelEvaluator.evaluate(StyleModelCompiler.compile(m), context: context(m)).parameters.tone.curve, .identity)
    }
}
