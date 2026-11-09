import XCTest
import Metal
import ImagingCore
import ImageRendering
@testable import ImageAnalysis

final class TemporalResponseFitterTests: XCTestCase {
    func model() throws -> CompiledCameraModel {
        var model=CameraModel(identity:.init(id:"temporal",camera:"synthetic",mode:"SDR"))
        func matrix(_ gain:Double)->ControlValue { .matrix(.init(values:[gain,0,0,0,gain,0,0,0,gain])) }
        model.responses=[.init(target:"color.matrix",expression:.singleAxis(axis:.target(.exposureBiasEV),nodes:[.init(0,matrix(0.4)),.init(1,matrix(0.9))],boundary:.reject))]
        return try CameraModelCompiler.compile(model)
    }
    func sequence(_ model:CompiledCameraModel,id:String,dt:[Double],split:CalibrationSplit = .train,delay:Double?=0) throws -> ResponseSequence {
        var times=[0.0]
        for i in 1..<90 { times.append(times.last!+dt[(i-1)%dt.count]) }
        let transition=12,start=times[transition-1]
        let frames=try times.enumerated().map { index,time -> ResponseSequence.Frame in
            let stamp=FrameStamp(streamID:id,generation:1,index:UInt64(index),presentationTime:time,duration:dt[index%dt.count])
            var observations=FrameObservations(stamp:stamp,sourceID:"source",calibrationID:"calibration",featureDigest:model.featureDigest)
            observations.captureConditions.iso=100
            var target=CaptureConditions();target.exposureBiasEV=index < transition ? 0:1
            let context=EvaluationContext(evaluationStamp:stamp,observations:observations,targetConditions:target)
            let record=DecisionRecord(modelDigest:model.identity,inputRecipeDigest:String(repeating:"a",count:64),resourceDigest:Digest.data(try JSON.encode(model.definition.appearance.resources)),context:context,seed:0,currentInput:.init(stamp:stamp,inputID:"frame-\(index)",sourceID:"source",calibrationID:"calibration",effectiveRecipeDigest:String(repeating:"a",count:64),captureConditions:observations.captureConditions))
            // The desired value is held over the interval ending at this sample, as declared by the reducer.
            let gain=index < transition ? 0.4:0.4+0.5*(1-exp(-(time-start)/0.5))
            return .init(record:record,targetPresentationTime:time+(delay ?? 0),measurements:[gain,0,0,0,gain,0,0,0,gain])
        }
        return .init(id:id,sceneID:id,split:split,mode:.sameFrame,captureDelaySeconds:delay,captureUncertaintySeconds:0,frames:frames)
    }
    func options() -> TemporalFitOptions {
        .init(bounds:[.init(target:"color.matrix",timeConstantSeconds:.init(lower:0.05,upper:1.5),hysteresis:.init(lower:0,upper:0))],maximumCaptureUncertaintySeconds:0,optimization:.init(maxIterations:80,convergenceTolerance:1e-7))
    }
    func testKnownTemporalResponseRecovery() async throws {
        let model=try model()
        for (index,steps) in [[1.0/30],[1.0/60],[1.0/24,1.0/80,1.0/33]].enumerated() {
            let sequence=try sequence(model,id:"rate-\(index)",dt:steps)
            let fit=try await TemporalResponseFitter.fit([sequence],model:model,policy:.init(),options:options(),predictor:TypedControlTemporalPredictor(targets:["color.matrix"]))
            let tau=try XCTUnwrap(fit.policy.rules.first?.timeConstantSeconds)
            XCTAssertLessThanOrEqual(abs(tau-0.5)/0.5,0.05)
            XCTAssertNotNil(fit.trainResidual)
        }
    }
    func testSeparateConstantSequencesDoNotEstablishTimingExcitation() async throws {
        let compiled=try model()
        let sequences=try [0.0,1.0].enumerated().map { index,value -> ResponseSequence in
            let original=try sequence(compiled,id:"constant-\(index)",dt:[1.0/30])
            let gain=0.4+0.5*value
            let frames=original.frames.map { frame -> ResponseSequence.Frame in
                var record=frame.record;record.context.targetConditions.exposureBiasEV=value
                return .init(record:record,targetPresentationTime:frame.targetPresentationTime,measurements:[gain,0,0,0,gain,0,0,0,gain])
            }
            return .init(id:original.id,sceneID:original.sceneID,split:.train,mode:.sameFrame,captureDelaySeconds:0,captureUncertaintySeconds:0,frames:frames)
        }
        let fit=try await TemporalResponseFitter.fit(sequences,model:compiled,policy:.init(),options:options(),predictor:TypedControlTemporalPredictor(targets:["color.matrix"]))
        XCTAssertFalse(fit.converged);XCTAssertEqual(fit.policy,compiled.definition.adaptation)
        XCTAssertNil(fit.trainResidual)
    }
    func testUnknownCaptureDelayPreventsTimingClaim() async throws {
        let model=try model(),sequence=try sequence(model,id:"unknown-delay",dt:[1.0/30],delay:nil)
        let fit=try await TemporalResponseFitter.fit([sequence],model:model,policy:.init(),options:options(),predictor:TypedControlTemporalPredictor(targets:["color.matrix"]))
        XCTAssertEqual(fit.policy,model.definition.adaptation)
        XCTAssertNil(fit.trainResidual)
        XCTAssertTrue(fit.unresolved.contains{$0.contains("capture delay")})
    }
    func testDeclaredDelayHasSeparateModeAndSameReducerRecovery() async throws {
        var definition=try model().definition
        definition.observations.validity.maxAgeFrames=1;definition.observations.validity.maxAgeSeconds=0.04
        let compiled=try CameraModelCompiler.compile(definition)
        let original=try sequence(compiled,id:"delayed",dt:[1.0/30])
        let frames=original.frames.map { frame -> ResponseSequence.Frame in
            var record=frame.record
            record.context.evaluationStamp.index+=1
            record.context.evaluationStamp.presentationTime+=1.0/30
            let facts=record.currentInput!
            record.currentInput = .init(stamp:record.context.evaluationStamp,inputID:facts.inputID,sourceID:facts.sourceID,calibrationID:facts.calibrationID,effectiveRecipeDigest:facts.effectiveRecipeDigest,captureConditions:facts.captureConditions)
            return .init(record:record,targetPresentationTime:frame.targetPresentationTime+1.0/30,measurements:frame.measurements)
        }
        let delayed=ResponseSequence(id:"delayed",sceneID:"delayed",split:.train,mode:.declaredDelay,captureDelaySeconds:0,captureUncertaintySeconds:0,frames:frames)
        let fit=try await TemporalResponseFitter.fit([delayed],model:compiled,policy:.init(),options:options(),predictor:TypedControlTemporalPredictor(targets:["color.matrix"]))
        XCTAssertLessThanOrEqual(abs(try XCTUnwrap(fit.policy.rules.first?.timeConstantSeconds)-0.5)/0.5,0.05)
        do {
            _=try await TemporalResponseFitter.fit([delayed,sequence(compiled,id:"same-frame",dt:[1.0/30])],model:compiled,policy:.init(),options:options(),predictor:TypedControlTemporalPredictor(targets:["color.matrix"]))
            XCTFail("Timing modes must not be pooled")
        } catch { XCTAssertTrue(String(describing:error).contains("separately")) }
    }
    func testTemporalAcceptanceUntouchedAndRecordMutationChangesIdentity() async throws {
        let model=try model(),original=try sequence(model,id:"train",dt:[1.0/30])
        let held=ResponseSequence(id:"held",sceneID:"held",split:.acceptance,mode:.declaredDelay,captureDelaySeconds:nil,captureUncertaintySeconds:nil,frames:[])
        let a=try await TemporalResponseFitter.fit([original,held],model:model,policy:.init(),options:options(),predictor:TypedControlTemporalPredictor(targets:["color.matrix"]))
        var frames=original.frames
        var record=frames[0].record;record.seed=1
        frames[0] = .init(record:record,targetPresentationTime:frames[0].targetPresentationTime,measurements:frames[0].measurements)
        let changed=ResponseSequence(id:original.id,sceneID:original.sceneID,split:.train,mode:.sameFrame,captureDelaySeconds:0,captureUncertaintySeconds:0,frames:frames)
        let b=try await TemporalResponseFitter.fit([changed],model:model,policy:.init(),options:options(),predictor:TypedControlTemporalPredictor(targets:["color.matrix"]))
        XCTAssertEqual(a.policy,b.policy)
        XCTAssertEqual(a.sequenceIDs,["train"])
        XCTAssertNotNil(a.measurementDigest)
        XCTAssertNotEqual(a.measurementDigest,b.measurementDigest)
    }
    func testStepThenMissingHoldUsesRawAutomaticHistory() async throws {
        var definition=try model().definition
        definition.responses[0].missing = .hold(maxAgeSeconds:10)
        var rule=AdaptationRule(target:"color.matrix",timeConstantSeconds:0.2);rule.maximumMissingSeconds=10
        definition.adaptation.rules=[rule]
        let compiled=try CameraModelCompiler.compile(definition),original=try sequence(compiled,id:"held-step",dt:[1.0/30])
        let frames=original.frames.enumerated().map { index,frame -> ResponseSequence.Frame in
            var record=frame.record
            if index>=14 { record.context.targetConditions.exposureBiasEV=nil }
            return .init(record:record,targetPresentationTime:frame.targetPresentationTime,measurements:frame.measurements)
        }
        let held=ResponseSequence(id:original.id,sceneID:original.sceneID,split:.train,mode:.sameFrame,captureDelaySeconds:0,captureUncertaintySeconds:0,frames:frames)
        let fit=try await TemporalResponseFitter.fit([held],model:compiled,policy:.init(),options:options(),predictor:TypedControlTemporalPredictor(targets:["color.matrix"]))
        XCTAssertLessThanOrEqual(abs(try XCTUnwrap(fit.policy.rules.first?.timeConstantSeconds)-0.5)/0.5,0.05)
        XCTAssertLessThan(fit.trainResidual ?? 1,0.001)
    }
    func testSeekResetBeginsFreshChronology() async throws {
        let compiled=try model(),original=try sequence(compiled,id:"seek",dt:[1.0/30])
        let frames=original.frames.enumerated().map { index,frame -> ResponseSequence.Frame in
            guard index>=45 else { return frame }
            var record=frame.record
            let stamp=FrameStamp(streamID:"seek",generation:2,index:UInt64(index-45),presentationTime:Double(index-45)/30,duration:1.0/30)
            record.context.evaluationStamp=stamp;record.context.observations.stamp=stamp
            if index==45 { record.event = .reset(.seek) }
            let facts=record.currentInput!
            record.currentInput = .init(stamp:stamp,inputID:facts.inputID,sourceID:facts.sourceID,calibrationID:facts.calibrationID,effectiveRecipeDigest:facts.effectiveRecipeDigest,captureConditions:facts.captureConditions)
            return .init(record:record,targetPresentationTime:stamp.presentationTime,measurements:[0.9,0,0,0,0.9,0,0,0,0.9])
        }
        let sequence=ResponseSequence(id:original.id,sceneID:original.sceneID,split:.train,mode:.sameFrame,captureDelaySeconds:0,captureUncertaintySeconds:0,frames:frames)
        let fit=try await TemporalResponseFitter.fit([sequence],model:compiled,policy:.init(),options:options(),predictor:TypedControlTemporalPredictor(targets:["color.matrix"]))
        XCTAssertLessThanOrEqual(abs(try XCTUnwrap(fit.policy.rules.first?.timeConstantSeconds)-0.5)/0.5,0.05)
    }
    func testFlatActualForwardResponseCannotIdentifyTiming() async throws {
        struct Black:TemporalResponsePredicting {
            func predict(_ frame:ResponseSequence.Frame,controls:AutomaticControls,model:CompiledCameraModel) async throws -> [Double] { [Double](repeating:0,count:9) }
        }
        let compiled=try model(),original=try sequence(compiled,id:"black",dt:[1.0/30])
        let frames=original.frames.map{ResponseSequence.Frame(record:$0.record,targetPresentationTime:$0.targetPresentationTime,measurements:[Double](repeating:0,count:9))}
        let sequence=ResponseSequence(id:original.id,sceneID:original.sceneID,split:.train,mode:.sameFrame,captureDelaySeconds:0,captureUncertaintySeconds:0,frames:frames)
        let fit=try await TemporalResponseFitter.fit([sequence],model:compiled,policy:.init(),options:options(),predictor:Black())
        XCTAssertFalse(fit.converged)
        XCTAssertEqual(fit.policy,compiled.definition.adaptation)
        XCTAssertNil(fit.trainResidual)
        XCTAssertTrue(fit.unresolved.contains{$0.contains("forward") && $0.contains("timing")})
    }
    func testTemporalPacketRequiresCompleteMatchingCurrentFacts() async throws {
        let compiled=try model(),original=try sequence(compiled,id:"facts",dt:[1.0/30])
        for mutation in 0..<3 {
            var frames=original.frames,record=original.frames[0].record
            if mutation==0 { record.currentInput=nil }
            else if mutation==1 { record.context.observations.captureConditions.iso=400 }
            else { record.context.observations.features=[.init(id:"foreign",value:1)] }
            frames[0] = .init(record:record,targetPresentationTime:frames[0].targetPresentationTime,measurements:frames[0].measurements)
            let bad=ResponseSequence(id:original.id,sceneID:original.sceneID,split:.train,mode:.sameFrame,captureDelaySeconds:0,captureUncertaintySeconds:0,frames:frames)
            do {
                _=try await TemporalResponseFitter.fit([bad],model:compiled,policy:.init(),options:options(),predictor:TypedControlTemporalPredictor(targets:["color.matrix"]))
                XCTFail("Incomplete or mismatched whole packet must reject")
            } catch { }
        }
    }
    func testB7PixelStepReplayUsesFittedCorePolicy() async throws {
        guard let device=MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let model=try model(),sequence=try sequence(model,id:"pixel-step",dt:[1.0/30])
        let fit=try await TemporalResponseFitter.fit([sequence],model:model,policy:.init(),options:options(),predictor:TypedControlTemporalPredictor(targets:["color.matrix"]))
        var execution=ExecutionProfile(width:1,height:1,budget:.init(maxInFlightFrames:1,maxResidentBytes:64*1024*1024));execution.precision = .float32
        let renderer=try LumeraRenderer(device:device,precision:.float32)
        let predictor=try B7CameraResponseScorer(renderer:renderer,working:.init(referenceRenditionID:"temporal-working"),execution:execution,resources:ModelResourceSet())
        let source=[0.4,0.5,0.6],indices=Set([0,11,12,20,50,89])
        var state:AdaptationState?,rendered=[[Double]]()
        for (index,frame) in sequence.frames.enumerated() {
            let controls=try CameraModelEvaluator.evaluate(model,context:frame.record.context)
            let reduced=try AdaptationReducer.reduce(controls,state:state,stamp:frame.record.context.evaluationStamp,event:nil,policy:fit.policy)
            state=reduced.state
            guard indices.contains(index) else { continue }
            let targetGain=frame.measurements[0]
            let expected=source.map { value -> Double in
                let linear=value<=0.04045 ? value/12.92:pow((value+0.055)/1.055,2.4)
                let x=linear*targetGain
                return x<=0.0031308 ? 12.92*x:1.055*pow(x,1/2.4)-0.055
            }
            let pixels=try await predictor.predict(.init(record:frame.record,targetPresentationTime:frame.targetPresentationTime,measurements:expected,inputColors:[source]),controls:reduced.controls,model:model)
            for (actual,target) in zip(pixels,expected) { XCTAssertEqual(actual,target,accuracy:0.002) }
            rendered.append(pixels)
        }
        XCTAssertEqual(rendered[0][0],rendered[1][0],accuracy:0.00002)
        XCTAssertGreaterThan(rendered[2][0],rendered[1][0]+0.005)
        XCTAssertGreaterThan(rendered.last![0],rendered[0][0]+0.08)
    }

}
