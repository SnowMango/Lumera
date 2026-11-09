import XCTest
@testable import ImagingCore
final class AdaptationReducerTests: XCTestCase {
    func stamp(_ t: Double, _ i: UInt64 = 0) -> FrameStamp { .init(streamID: "stream", generation: 1, index: i, presentationTime: t, duration: 1/60) }
    func controls(_ v: Double, _ t: Double = 0, _ i: UInt64 = 0) -> AutomaticControls {
        var p = StyleParameters(); p.glow.amount = v
        var c = AutomaticControls(parameters: p, modelID: "model", sourceID: "source", calibrationID: "calibration", featureDigest: "features")
        c.provenance = [.init(target: "glow.amount", lastValidStamp: stamp(t, i))]; return c
    }
    func policy(_ tau: Double = 1) -> AdaptationPolicy { var p = AdaptationPolicy(); p.rules = [.init(target: "glow.amount", timeConstantSeconds: tau)]; return p }
    func testRateIndependentExponentialResponse() throws {
        for fps in [30, 60] {
            var r = try AdaptationReducer.reduce(controls(0), state: nil, stamp: stamp(0), event: nil, policy: policy())
            for i in 1...fps { let t = Double(i)/Double(fps); r = try AdaptationReducer.reduce(controls(1,t,UInt64(i)), state: r.state, stamp: stamp(t,UInt64(i)), event: nil, policy: policy()) }
            XCTAssertEqual(r.controls.parameters.glow.amount, 1-exp(-1), accuracy: 1e-9)
        }
    }
    func testResetAndChronology() throws {
        let a = try AdaptationReducer.reduce(controls(0,1,1), state: nil, stamp: stamp(1,1), event: nil, policy: policy())
        for s in [stamp(1,2), stamp(0,2), stamp(2,1)] {
            XCTAssertThrowsError(try AdaptationReducer.reduce(controls(1), state: a.state, stamp: s, event: nil, policy: policy()))
        }
        let b = try AdaptationReducer.reduce(controls(1), state: a.state, stamp: stamp(0), event: .reset(.seek), policy: policy())
        XCTAssertEqual(b.controls.parameters.glow.amount, 1)
        XCTAssertEqual(b.controls.diagnostics.last?.code, .temporalReset)
    }
    func testMissingObservationExpiresWithoutRefreshingFreshness() throws {
        var p = policy(); p.rules[0].maximumMissingSeconds = 1; p.rules[0].expired = .constant(.scalar(0.2))
        for valid in [false, true] {
            var c = controls(0.5); c.provenance[0] = .init(target: "glow.amount", lastValidStamp: valid ? stamp(0) : nil, isFallback: true)
            let a = try AdaptationReducer.reduce(c, state: nil, stamp: stamp(0), event: nil, policy: p)
            let b = try AdaptationReducer.reduce(c, state: a.state, stamp: stamp(0.8,1), event: nil, policy: p)
            let d = try AdaptationReducer.reduce(c, state: b.state, stamp: stamp(1.1,2), event: nil, policy: p)
            XCTAssertEqual(d.controls.parameters.glow.amount, 0.2)
            XCTAssertEqual(d.controls.provenance[0].lastValidStamp, valid ? stamp(0) : nil)
            XCTAssertEqual(d.controls.diagnostics.last?.code, .missingExpired)
        }
        p.rules[0].expired = .reject
        var c = controls(1); c.provenance[0].isFallback = true
        XCTAssertThrowsError(try AdaptationReducer.reduce(c, state: nil, stamp: stamp(2,2), event: nil, policy: p))
    }
    func testUnlockStartsAtLockedValue() throws {
        let lock = ControlOverride(target: "glow.amount", value: .scalar(0.7))
        let a = try AdaptationReducer.reduce(controls(0), state: nil, stamp: stamp(0), event: .lock([lock]), policy: policy())
        let b = try AdaptationReducer.reduce(controls(0,1,1), state: a.state, stamp: stamp(1,1), event: nil, policy: policy())
        XCTAssertEqual(b.controls.parameters.glow.amount, 0.7)
        let c = try AdaptationReducer.reduce(controls(0,2,2), state: b.state, stamp: stamp(2,2), event: .unlock([lock]), policy: policy())
        XCTAssertEqual(c.controls.parameters.glow.amount, 0.7)
        let d = try AdaptationReducer.reduce(controls(0,3,3), state: c.state, stamp: stamp(3,3), event: nil, policy: policy())
        XCTAssertEqual(d.controls.parameters.glow.amount, 0.7*exp(-1), accuracy: 1e-9)
        XCTAssertThrowsError(try AdaptationReducer.reduce(controls(0,1,1), state: a.state, stamp: stamp(1,1), event: .unlock([.init(target: "glow.amount", value: .scalar(0.3))]), policy: policy()))
    }
    func testIrregularStepsImmediateAndInitialization() throws {
        var r = try AdaptationReducer.reduce(controls(0), state: nil, stamp: stamp(0), event: nil, policy: policy())
        for (i,t) in [0.01,0.3,0.31,1.0].enumerated() {
            r = try AdaptationReducer.reduce(controls(1,t,UInt64(i+1)), state: r.state, stamp: stamp(t,UInt64(i+1)), event: nil, policy: policy())
        }
        XCTAssertEqual(r.controls.parameters.glow.amount,1-exp(-1),accuracy:1e-9)
        var p = policy(0); p.rules[0].initialization = .constant(.scalar(0))
        let a = try AdaptationReducer.reduce(controls(1), state: nil, stamp: stamp(0), event: nil, policy: p)
        XCTAssertEqual(a.controls.parameters.glow.amount,0)
        let b = try AdaptationReducer.reduce(controls(1,0.01,1), state:a.state,stamp:stamp(0.01,1),event:nil,policy:p)
        XCTAssertEqual(b.controls.parameters.glow.amount,1)
        p.rules[0].hysteresis = 0.1
        let c = try AdaptationReducer.reduce(controls(0.05),state:nil,stamp:stamp(0),event:nil,policy:p)
        XCTAssertEqual(try AdaptationReducer.reduce(controls(0.05,1,1),state:c.state,stamp:stamp(1,1),event:nil,policy:p).controls.parameters.glow.amount,0)
    }
    func testIdentityChangesAndInvalidStateRejected() throws {
        let a = try AdaptationReducer.reduce(controls(0),state:nil,stamp:stamp(0),event:nil,policy:policy())
        for key in ["model","source","calibration","features","stream","generation"] {
            var c = controls(1,1,1); var s = stamp(1,1)
            switch key { case "model":c.modelID = "other"; case "source":c.sourceID = "other"; case "calibration":c.calibrationID = "other"; case "features":c.featureDigest = "other"; case "stream":s.streamID = "other"; default:s.generation = 2 }
            c.provenance[0].lastValidStamp = s
            XCTAssertThrowsError(try AdaptationReducer.reduce(c,state:a.state,stamp:s,event:nil,policy:policy()),key)
            XCTAssertNoThrow(try AdaptationReducer.reduce(c,state:a.state,stamp:s,event:.reset(.sourceChanged),policy:policy()))
        }
        let bad = AdaptationState(controls:a.controls,stamp:a.state.stamp,policyDigest:a.state.policyDigest,missingSince:["glow.amount":.nan])
        XCTAssertThrowsError(try AdaptationReducer.reduce(controls(1,1,1),state:bad,stamp:stamp(1,1),event:nil,policy:policy()))
        XCTAssertEqual(try AdaptationReducer.reduce(controls(1),state:nil,stamp:stamp(0),event:nil,policy:policy()).controls.parameters.glow.amount,1)
    }
    func testConvexWeightsAndImmediateTypedBlocks() throws {
        var p = AdaptationPolicy(); p.rules = [.init(target:"style.lutWeights",timeConstantSeconds:1)]
        var c = controls(0); c.lutWeights = [.init(resourceID:"a",weight:1)]
        let a = try AdaptationReducer.reduce(c,state:nil,stamp:stamp(0),event:nil,policy:p)
        c.lutWeights = [.init(resourceID:"b",weight:1)]
        let b = try AdaptationReducer.reduce(c,state:a.state,stamp:stamp(1,1),event:nil,policy:p)
        XCTAssertEqual(b.controls.lutWeights.first(where:{$0.resourceID == "b"})!.weight,1-exp(-1),accuracy:1e-9)
        XCTAssertNoThrow(try ResourceWeight.validate(b.controls.lutWeights))
        for target in ["tone.curve","color.matrix"] { p.rules = [.init(target:target,timeConstantSeconds:1)]; XCTAssertNoThrow(try AdaptationReducer.reduce(c,state:nil,stamp:stamp(0),event:nil,policy:p)) }
    }
    func testFinalConstraintsAndInvalidPolicy() throws {
        var p = policy(); p.rules[0].timeConstantSeconds = .nan
        XCTAssertThrowsError(try AdaptationReducer.reduce(controls(0),state:nil,stamp:stamp(0),event:nil,policy:p))
        p = policy(); p.rules[0].expired = .hold(maxAgeSeconds:1)
        XCTAssertThrowsError(try AdaptationReducer.reduce(controls(0),state:nil,stamp:stamp(0),event:nil,policy:p))
        let locks = [ControlOverride(target:"detail.fineSigma",value:.scalar(8)),ControlOverride(target:"detail.midSigma",value:.scalar(1))]
        XCTAssertThrowsError(try AdaptationReducer.reduce(controls(0),state:nil,stamp:stamp(0),event:.lock(locks),policy:policy()))
    }
    func testLockedMissingValueExpiresOnlyAfterUnlockContinuityFrame() throws {
        var c = controls(0); c.provenance[0] = .init(target:"glow.amount",lastValidStamp:nil,isFallback:true)
        let lock = ControlOverride(target:"glow.amount",value:.scalar(0.7))
        let a = try AdaptationReducer.reduce(c,state:nil,stamp:stamp(0),event:.lock([lock]),policy:policy())
        let b = try AdaptationReducer.reduce(c,state:a.state,stamp:stamp(1,1),event:nil,policy:policy())
        XCTAssertEqual(b.controls.parameters.glow.amount,0.7)
        let d = try AdaptationReducer.reduce(c,state:b.state,stamp:stamp(2,2),event:.unlock([lock]),policy:policy())
        XCTAssertEqual(d.controls.parameters.glow.amount,0.7)
        XCTAssertThrowsError(try AdaptationReducer.reduce(c,state:d.state,stamp:stamp(3,3),event:nil,policy:policy()))
    }
    func testFallbackCannotIntroduceValidityAndMalformedMissingHistoryRejects() throws {
        var p = policy(); p.rules[0].maximumMissingSeconds = 1
        var c = controls(0); c.provenance[0] = .init(target:"glow.amount",lastValidStamp:nil,isFallback:true)
        let a = try AdaptationReducer.reduce(c,state:nil,stamp:stamp(0),event:nil,policy:p)
        c.provenance[0].lastValidStamp = stamp(0.8,1)
        let b = try AdaptationReducer.reduce(c,state:a.state,stamp:stamp(0.8,1),event:nil,policy:p)
        XCTAssertNil(b.controls.provenance[0].lastValidStamp)
        c.provenance[0].lastValidStamp = stamp(1.2,2)
        XCTAssertThrowsError(try AdaptationReducer.reduce(c,state:b.state,stamp:stamp(1.2,2),event:nil,policy:p))
        let malformed = AdaptationState(controls:a.controls,stamp:a.state.stamp,policyDigest:a.state.policyDigest)
        XCTAssertThrowsError(try AdaptationReducer.reduce(c,state:malformed,stamp:stamp(1.2,2),event:nil,policy:p))
    }
    func testOverflowingElapsedTimeAndMissingAgeReject() throws {
        let limit = Double.greatestFiniteMagnitude
        let initial = try AdaptationReducer.reduce(controls(0, -limit), state: nil, stamp: stamp(-limit), event: nil, policy: policy())
        XCTAssertThrowsError(try AdaptationReducer.reduce(controls(1, limit, 1), state: initial.state, stamp: stamp(limit, 1), event: nil, policy: policy()))
        // Missing age can overflow even on the first reducer call, without history.
        var missing = controls(0, -limit); missing.provenance[0].isFallback = true
        var p = policy(); p.rules[0].expired = .constant(.scalar(0.2))
        XCTAssertThrowsError(try AdaptationReducer.reduce(missing, state: nil, stamp: stamp(limit, 1), event: nil, policy: p))
        // A finite frame delta does not guarantee a finite age since validity.
        let held = try AdaptationReducer.reduce(missing, state: nil, stamp: stamp(0, 1), event: nil, policy: p)
        XCTAssertThrowsError(try AdaptationReducer.reduce(missing, state: held.state, stamp: stamp(limit, 2), event: nil, policy: p))
    }
}
