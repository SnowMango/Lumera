import XCTest
import ImagingCore
@testable import ImagingRuntime
final class DecisionReplayTests: XCTestCase {
    let recipe = String(repeating:"a",count:64)
    func model() throws -> CompiledCameraModel {
        var m = CameraModel(identity:.init(id:"test",camera:"test",mode:"test"))
        m.observations.features = [.init(id:"mean",statistic:.meanGreen)]
        m.responses = [.init(target:"glow.amount",expression:.singleAxis(axis:.feature("mean"),nodes:[.init(0,.scalar(0)),.init(1,.scalar(1))],boundary:.clamp))]
        m.adaptation.rules = [.init(target:"glow.amount",timeConstantSeconds:1)]
        m.edits.overrideTargets = ["glow.amount"]
        return try CameraModelCompiler.compile(m)
    }
    func record(_ m:CompiledCameraModel,_ t:Double = 0,_ i:UInt64 = 0,_ value:Double = 0) throws -> DecisionRecord {
        let stamp = FrameStamp(streamID:"s",generation:1,index:i,presentationTime:t,duration:0.1)
        var o = FrameObservations(stamp:stamp,sourceID:"source",calibrationID:"cal",featureDigest:m.featureDigest); o.features = [.init(id:"mean",value:value)]
        return .init(modelDigest:m.identity,inputRecipeDigest:recipe,resourceDigest:Digest.data(try JSON.encode(m.definition.appearance.resources)),context:.init(evaluationStamp:stamp,observations:o),seed:UInt32(i+10),currentInput:.init(stamp:stamp,inputID:"input-\(i)",sourceID:o.sourceID,calibrationID:o.calibrationID,effectiveRecipeDigest:recipe,captureConditions:o.captureConditions))
    }
    func testReplayDeterministicPreservesSourceIndexSeedAndInput() throws {
        let m = try model(); let records = try [record(m),record(m,1,60,1)]
        let a = try DecisionReplay.evaluate(records,model:m), b = try DecisionReplay.evaluate(records,model:m)
        XCTAssertEqual(a,b); XCTAssertEqual(a[1].sourceFrameIndex,60); XCTAssertEqual(a[1].seed,70); XCTAssertEqual(a[1].inputDigest,"input-60")
        XCTAssertEqual(a[1].controls.parameters.glow.amount,1-exp(-1),accuracy:1e-9)
    }
    func testDuplicateReverseRequireReset() throws {
        let m = try model(); let first = try record(m,1,1)
        XCTAssertThrowsError(try DecisionReplay.evaluate([first,first],model:m))
        var reset = try record(m); reset.event = .reset(.seek)
        XCTAssertNoThrow(try DecisionReplay.evaluate([first,reset],model:m))
    }
    func testMissingAndMismatchedIdentityDataReject() throws {
        let m = try model()
        for kind in ["facts","version","model","resource","recipe","stamp"] {
            var r = try record(m)
            switch kind { case "facts":r.currentInput = nil; case "version":r.version = 2; case "model":r.modelDigest = "bad"; case "resource":r.resourceDigest = "bad"; case "recipe":r.inputRecipeDigest = "bad"; default:r.context.evaluationStamp.index = 1 }
            XCTAssertThrowsError(try DecisionReplay.evaluate([r],model:m),kind)
        }
    }
    func testReplayMatchesExplicitPurePipeline() throws {
        let m = try model(); var records = try [record(m),record(m,0.5,30,1),record(m,1,60,0.5)]
        records[1].edits.overrides = [.init(target:"glow.amount",value:.scalar(0.8))]
        var state: AdaptationState?
        for (r,actual) in zip(records,try DecisionReplay.evaluate(records,model:m)) {
            let a = try CameraModelEvaluator.evaluate(m,context:r.context)
            let t = try AdaptationReducer.reduce(a,state:state,stamp:r.context.evaluationStamp,event:r.event,policy:m.definition.adaptation)
            let e = try EditResolver.resolve(r.edits,automatic:t.controls,model:m)
            state = t.state
            XCTAssertEqual(actual.controls.parameters,e.parameters)
            if r.context.evaluationStamp.index == 30 { XCTAssertEqual(actual.controls.parameters.glow.amount,0.8) }
        }
    }
    func testRecipeChangeRequiresReset() throws {
        let m = try model(); let first = try record(m); var next = try record(m,1,1)
        let f = next.currentInput!; let changed = String(repeating:"b",count:64)
        next.inputRecipeDigest = changed
        next.currentInput = .init(stamp:f.stamp,inputID:f.inputID,sourceID:f.sourceID,calibrationID:f.calibrationID,effectiveRecipeDigest:changed,captureConditions:f.captureConditions)
        XCTAssertThrowsError(try DecisionReplay.evaluate([first,next],model:m))
        next.event = .reset(.sourceChanged)
        XCTAssertNoThrow(try DecisionReplay.evaluate([first,next],model:m))
    }
    func testColdMissingFallbackExpiresAndLockEventsPreserveValues() throws {
        var definition = try model().definition
        definition.responses[0].missing = .constant(.scalar(0.1))
        definition.adaptation.rules[0].maximumMissingSeconds = 1
        definition.adaptation.rules[0].expired = .constant(.scalar(0.2))
        let m = try CameraModelCompiler.compile(definition)
        var records = try [record(m),record(m,0.5,1),record(m,2,2)]
        for i in records.indices { records[i].context.observations.features[0].value = nil }
        let missing = try DecisionReplay.evaluate(records,model:m)
        XCTAssertEqual(missing[0].controls.parameters.glow.amount,0.1)
        XCTAssertEqual(missing[1].controls.parameters.glow.amount,0.1)
        XCTAssertEqual(missing[2].controls.parameters.glow.amount,0.2)
        let lock = ControlOverride(target:"glow.amount",value:.scalar(0.7))
        records[0].event = .lock([lock]); records[0].edits.locks = [lock]
        records[2].event = .unlock([lock])
        let locked = try DecisionReplay.evaluate(records,model:m)
        XCTAssertTrue(locked.allSatisfy { $0.controls.parameters.glow.amount == 0.7 })
        records[0].event = nil
        XCTAssertThrowsError(try DecisionReplay.evaluate([records[0]],model:m))
    }
    func testDelayedReplayChecksCurrentCaptureFacts() throws {
        var definition = try model().definition
        definition.observations.validity.maxAgeFrames = 2; definition.observations.validity.maxAgeSeconds = 1
        definition.observations.validity.sourceChangeTolerances = [.init(axis:.iso,maxCoordinateDelta:0.1)]
        let m = try CameraModelCompiler.compile(definition)
        var r = try record(m,0.5,1,0.5)
        r.context.observations.stamp = try record(m).context.evaluationStamp
        r.context.observations.captureConditions.iso = 100
        let f = r.currentInput!; var capture = f.captureConditions; capture.iso = 400
        r.currentInput = .init(stamp:f.stamp,inputID:f.inputID,sourceID:f.sourceID,calibrationID:f.calibrationID,effectiveRecipeDigest:f.effectiveRecipeDigest,captureConditions:capture)
        XCTAssertThrowsError(try DecisionReplay.evaluate([r],model:m))
    }
    func testLiveStepMatchesReplayAndUnlockCombinedEditsReject() throws {
        let m = try model(); let lock = ControlOverride(target:"glow.amount",value:.scalar(0.7))
        var a = try record(m); a.event = .lock([lock])
        var b = try record(m,1,1); b.event = .unlock([lock])
        let first = try DecisionReplay.step(a,model:m)
        let second = try DecisionReplay.step(b,model:m,state:first.state)
        XCTAssertEqual(try DecisionReplay.evaluate([a,b],model:m),[first.decision,second.decision])
        XCTAssertEqual(second.decision.controls.parameters.glow.amount,0.7)
        b.edits.visualOffsets = [.init(id:"unused",value:0.1)]
        XCTAssertThrowsError(try DecisionReplay.step(b,model:m,state:first.state))
        b.edits.visualOffsets = []; b.edits.strength = 0.5
        XCTAssertThrowsError(try DecisionReplay.step(b,model:m,state:first.state))
        b.edits.strength = nil; b.edits.overrides = [.init(target:"glow.amount",value:.scalar(0.3))]
        XCTAssertThrowsError(try DecisionReplay.step(b,model:m,state:first.state))
    }
    func testSameFrameMissingSourceUsesDeclaredFallbackButDelayedRejects() throws {
        var definition = try model().definition
        definition.observations.sourceConditions = [.iso]
        definition.observations.validity.maxAgeFrames = 1
        definition.observations.validity.maxAgeSeconds = 1
        definition.responses[0].expression = .singleAxis(axis:.source(.iso),nodes:[.init(100,.scalar(0)),.init(400,.scalar(1))],boundary:.clamp)
        definition.responses[0].missing = .constant(.scalar(0.25))
        let m = try CameraModelCompiler.compile(definition)
        let sameFrame = try record(m)
        XCTAssertNil(sameFrame.context.observations.captureConditions.iso)
        let result = try DecisionReplay.step(sameFrame,model:m)
        XCTAssertEqual(result.decision.controls.parameters.glow.amount,0.25)
        XCTAssertNil(result.decision.controls.automatic.provenance[0].lastValidStamp)
        var delayed = try record(m,0.5,1)
        delayed.context.observations = sameFrame.context.observations
        XCTAssertThrowsError(try DecisionReplay.step(delayed,model:m))
    }
    func testAutomaticAndTemporalDiagnosticsAppearOnceInFinalList() throws {
        var definition = try model().definition
        definition.responses[0].missing = .constant(.scalar(0.25))
        let m = try CameraModelCompiler.compile(definition)
        var r = try record(m)
        r.context.observations.features[0].value = nil
        r.event = .reset(.sceneCut)
        let result = try DecisionReplay.step(r,model:m).decision
        XCTAssertEqual(result.controls.diagnostics.filter { $0.code == .missingObservation }.count,1)
        XCTAssertEqual(result.controls.diagnostics.filter { $0.code == .temporalReset }.count,1)
        XCTAssertEqual(result.controls.automatic.diagnostics.filter { $0.code == .missingObservation }.count,1)
        XCTAssertEqual(result.controls.automatic.diagnostics.filter { $0.code == .temporalReset }.count,1)
    }
    func testExplicitLockSurvivesMissingRejectWithoutRefreshingValidity() throws {
        var definition = try model().definition
        definition.responses[0].missing = .reject
        let m = try CameraModelCompiler.compile(definition)
        let lock = ControlOverride(target:"glow.amount",value:.scalar(0.7))
        var first = try record(m); first.context.observations.features[0].value = nil; first.event = .lock([lock])
        let initial = try DecisionReplay.step(first,model:m)
        XCTAssertEqual(initial.decision.controls.parameters.glow.amount,0.7)
        XCTAssertNil(initial.state.fallback.controls.provenance[0].lastValidStamp)
        let valid = try DecisionReplay.step(record(m,1,1,1),model:m,state:initial.state)
        XCTAssertEqual(valid.state.fallback.controls.parameters.glow.amount,1,"Valid automatic observations must still evaluate while locked")
        XCTAssertEqual(valid.decision.controls.parameters.glow.amount,0.7)
        var missing = try record(m,2,2); missing.context.observations.features[0].value = nil
        let held = try DecisionReplay.step(missing,model:m,state:valid.state)
        XCTAssertEqual(held.decision.controls.parameters.glow.amount,0.7)
        XCTAssertEqual(held.state.fallback.controls.provenance[0].lastValidStamp,valid.decision.stamp)
        var unlock = try record(m,3,3); unlock.context.observations.features[0].value = nil; unlock.event = .unlock([lock])
        let continuous = try DecisionReplay.step(unlock,model:m,state:held.state)
        XCTAssertEqual(continuous.decision.controls.parameters.glow.amount,0.7)
        XCTAssertEqual(continuous.state.fallback.controls.provenance[0].lastValidStamp,valid.decision.stamp)
        var unprotected = try record(m,4,4); unprotected.context.observations.features[0].value = nil
        XCTAssertThrowsError(try DecisionReplay.step(unprotected,model:m,state:continuous.state))
    }
    func testExplicitLockDoesNotBypassOtherOwnersOrInvalidPackets() throws {
        var definition = try model().definition; definition.responses[0].missing = .reject
        let lock = ControlOverride(target:"glow.amount",value:.scalar(0.7))
        var second = definition.responses[0]; second.target = "color.exposureEV"; definition.responses.append(second)
        let twoOwners = try CameraModelCompiler.compile(definition)
        var missing = try record(twoOwners); missing.context.observations.features[0].value = nil; missing.event = .lock([lock])
        XCTAssertThrowsError(try DecisionReplay.step(missing,model:twoOwners))
        definition.responses.removeLast()
        definition.responses[0].expression = .singleAxis(axis:.feature("mean"),nodes:[.init(0,.scalar(0)),.init(1,.scalar(1))],boundary:.reject)
        let m = try CameraModelCompiler.compile(definition)
        var outside = try record(m,0,0,2); outside.event = .lock([lock])
        XCTAssertThrowsError(try DecisionReplay.step(outside,model:m))
        outside.context.observations.featureDigest = "wrong"
        XCTAssertThrowsError(try DecisionReplay.step(outside,model:m))
        var unsupported = try record(m); unsupported.event = .lock([.init(target:"color.exposureEV",value:.scalar(0))])
        XCTAssertThrowsError(try DecisionReplay.step(unsupported,model:m))
    }
    func testEvaluatorValidatesExplicitLockContextEvenWithValidObservations() throws {
        let m = try model(); let context = try record(m).context
        let lock = ControlOverride(target:"glow.amount",value:.scalar(0.7))
        XCTAssertThrowsError(try CameraModelEvaluator.evaluate(m,context:context,lockedControls:[lock,lock]))
        XCTAssertThrowsError(try CameraModelEvaluator.evaluate(m,context:context,lockedControls:[.init(target:"color.exposureEV",value:.scalar(0))]))
        XCTAssertThrowsError(try CameraModelEvaluator.evaluate(m,context:context,lockedControls:[.init(target:"glow.amount",value:.scalar(.nan))]))
        XCTAssertEqual(try CameraModelEvaluator.evaluate(m,context:context,lockedControls:[lock]).parameters.glow.amount,0)
    }
}
