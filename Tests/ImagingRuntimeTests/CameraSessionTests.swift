import XCTest
import CoreImage
import Metal
import ImagingCore
import ImageRendering
@testable import ImagingRuntime

/// Gates suspend at explicit driver boundaries; no timing sleeps or GPU-duration assumptions.
private actor SessionTestGate {
    private var arrived = false
    private var released = false
    private var arrivals: [CheckedContinuation<Void,Never>] = []
    private var releases: [CheckedContinuation<Void,Never>] = []
    func enter() async {
        arrived = true
        let listeners = arrivals; arrivals.removeAll()
        for listener in listeners { listener.resume() }
        if !released { await withCheckedContinuation { releases.append($0) } }
    }
    func waitForArrival() async {
        if !arrived { await withCheckedContinuation { arrivals.append($0) } }
    }
    func release() {
        released = true
        let listeners = releases; releases.removeAll()
        for listener in listeners { listener.resume() }
    }
}

private final class SessionTestOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var first = true
    func take() -> Bool { lock.lock(); defer { lock.unlock() }; let value = first; first = false; return value }
}
private enum SessionTestFailure: Error { case injectedGPUFailure }

final class CameraSessionTests: XCTestCase {
    struct Fixture {
        let renderer: LumeraRenderer
        let model: PreparedCameraModel
        let input: PreparedInput
    }
    func stamp(_ i:UInt64 = 0, generation:UInt64 = 0) -> FrameStamp {
        .init(streamID:"session",generation:generation,index:i,presentationTime:Double(i)/30,duration:1/30)
    }
    func fixture(maxFrames:Int = 2, delayed:Bool = false) async throws -> Fixture {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let renderer = try LumeraRenderer()
        let working = WorkingImageContract(referenceRenditionID:"fixture")
        var definition = CameraModel(identity:.init(id:"session",camera:"fixture",mode:"test"))
        definition.compatibility.referenceRenditionIDs = [working.referenceRenditionID]
        definition.edits.overrideTargets = ["color.exposureEV"]
        definition.observations.features = [.init(id:"mean",statistic:.meanGreen)]
        definition.responses = [.init(target:"color.exposureEV",expression:.singleAxis(axis:.feature("mean"),nodes:[.init(0,.scalar(0)),.init(1,.scalar(1))],boundary:.clamp))]
        definition.responses[0].missing = .constant(.scalar(0))
        definition.adaptation.rules = [.init(target:"color.exposureEV",timeConstantSeconds:0.5)]
        definition.adaptation.rules[0].maximumMissingSeconds = 1
        var execution = ExecutionProfile(width:4,height:4,budget:.init(maxInFlightFrames:maxFrames,maxResidentBytes:64*1024*1024))
        if delayed {
            definition.observations.validity.maxAgeFrames = 2
            definition.observations.validity.maxAgeSeconds = 1
            execution.statisticsLatency = .delayed(maxFrames:2,maxSeconds:1)
        }
        let model = try ModelPreparer(renderer:renderer).prepare(CameraModelCompiler.compile(definition),resources:.init(),execution:execution)
        let image = CIImage(color:CIColor(red:0.5,green:0.5,blue:0.5)).cropped(to:CGRect(x:0,y:0,width:4,height:4))
        let recipe = InputRecipe(id:"ci",backend:"coreImage",version:"1",decodedRendition:.baseImage)
        var descriptor = SourceDescriptor(id:"input",path:.processedPhoto); descriptor.recipeID = recipe.id
        let normalized = try await InputAdapter(renderer:renderer,working:working).prepare(.image(image),descriptor:descriptor,recipe:recipe,execution:execution)
        let input = try await InputNormalizer(renderer:renderer).normalize(normalized,calibration:nil,resources:.init())
        return .init(renderer:renderer,model:model,input:input)
    }
    func assertRendered(_ outcome:FrameOutcome, stamp:FrameStamp, file:StaticString = #filePath,line:UInt = #line) {
        guard case .rendered(let frame) = outcome else { return XCTFail("Expected rendered frame",file:file,line:line) }
        XCTAssertEqual(frame.stamp,stamp,file:file,line:line)
        XCTAssertEqual(frame.width,4,file:file,line:line)
    }
    func testSameFrameRecordsReplayWithoutReindexing() async throws {
        let f = try await fixture(); let session = try CameraSession(renderer:f.renderer,model:f.model,seed:42)
        for index in [UInt64(3),9] { assertRendered(try await session.enqueue(f.input,stamp:stamp(index)),stamp:stamp(index)) }
        let records = await session.takeRecords()
        XCTAssertEqual(records.map { $0.context.evaluationStamp.index },[3,9])
        let decisions = try DecisionReplay.evaluate(records,model:f.model.compiled)
        XCTAssertEqual(decisions.map(\.sourceFrameIndex),[3,9])
        XCTAssertEqual(decisions.map(\.seed),records.map(\.seed))
        XCTAssertEqual(decisions.map(\.inputDigest),[f.input.inputID,f.input.inputID])
        let drained = await session.takeRecords(); XCTAssertTrue(drained.isEmpty)
    }
    func testBoundedQueueReportsOriginalDroppedPTS() async throws {
        let f = try await fixture(maxFrames:1); let gate = SessionTestGate(); let live = SessionRenderDriver.live(f.renderer)
        let driver = SessionRenderDriver(observe:{ input,stamp,requirements,maxBytes in
            await gate.enter(); return try await live.observe(input,stamp,requirements,maxBytes)
        },submit:live.submit)
        let session = try CameraSession(model:f.model,backpressure:.dropUnsubmitted,seed:42,driver:driver)
        let first = Task { self.assertRendered(try await session.enqueue(f.input,stamp:self.stamp(4)),stamp:self.stamp(4)) }
        await gate.waitForArrival()
        let rejected = try await session.enqueue(f.input,stamp:stamp(7))
        guard case .dropped(let droppedStamp,_) = rejected else { await gate.release(); return XCTFail("Capacity should drop unsubmitted frame") }
        XCTAssertEqual(droppedStamp,stamp(7))
        await gate.release(); try await first.value
        let records = await session.takeRecords(); XCTAssertEqual(records.map { $0.context.evaluationStamp.index },[4])
        assertRendered(try await session.enqueue(f.input,stamp:stamp(10)),stamp:stamp(10))
        let afterDrop = await session.takeRecords(); XCTAssertEqual(afterDrop.map { $0.context.evaluationStamp.index },[10])
    }
    func testCancelBeforeSubmitDoesNotAdvanceStateOrRecord() async throws {
        let f = try await fixture(); let gate = SessionTestGate(); let live = SessionRenderDriver.live(f.renderer)
        let driver = SessionRenderDriver(observe:{ input,stamp,requirements,maxBytes in
            await gate.enter(); return try await live.observe(input,stamp,requirements,maxBytes)
        },submit:live.submit)
        let session = try CameraSession(model:f.model,backpressure:.wait,seed:42,driver:driver)
        let pending = Task { try await session.enqueue(f.input,stamp:self.stamp(5)) }
        await gate.waitForArrival(); pending.cancel(); await gate.release()
        let cancelled = try await pending.value
        guard case .dropped(let cancelledStamp,.cancelled) = cancelled else { return XCTFail("Expected pre-submit cancellation drop") }
        XCTAssertEqual(cancelledStamp,stamp(5))
        let records = await session.takeRecords(); XCTAssertTrue(records.isEmpty)
        // Cancellation consumes accepted source order but must not create adaptation history.
        assertRendered(try await session.enqueue(f.input,stamp:stamp(6)),stamp:stamp(6))
        let accepted = await session.takeRecords(); XCTAssertEqual(accepted.count,1)
        guard let record = accepted.first else { return }
        let raw = try CameraModelEvaluator.evaluate(f.model.compiled,context:record.context)
        let replayed = try DecisionReplay.evaluate(accepted,model:f.model.compiled)
        XCTAssertEqual(replayed[0].controls.parameters.color.exposureEV,raw.parameters.color.exposureEV)
        XCTAssertEqual(record.context.evaluationStamp,stamp(6))
    }
    func testDuplicateReverseFramesRequireExplicitReset() async throws {
        let f = try await fixture(); let session = try CameraSession(renderer:f.renderer,model:f.model)
        assertRendered(try await session.enqueue(f.input,stamp:stamp(10)),stamp:stamp(10))
        for index in [UInt64(10),9] {
            do { _ = try await session.enqueue(f.input,stamp:stamp(index)); XCTFail("Invalid chronology accepted") } catch { }
        }
        try await session.reset(.reset(.seek))
        assertRendered(try await session.enqueue(f.input,stamp:stamp(1,generation:1)),stamp:stamp(1,generation:1))
        do { try await session.reset(.lock([])); XCTFail("Non-reset event accepted by reset API") } catch { }
    }
    func testDelayedModeUsesOneWholePriorPacketAfterColdFallback() async throws {
        let f = try await fixture(delayed:true)
        let session = try CameraSession(renderer:f.renderer,model:f.model)
        assertRendered(try await session.enqueue(f.input,stamp:stamp(0)),stamp:stamp(0))
        assertRendered(try await session.enqueue(f.input,stamp:stamp(1)),stamp:stamp(1))
        let records = await session.takeRecords()
        XCTAssertEqual(records.count,2)
        guard records.count == 2 else { return }
        XCTAssertNil(records[0].context.observations.features.first?.value)
        XCTAssertEqual(records[1].context.observations.stamp,stamp(0))
        XCTAssertNotNil(records[1].context.observations.features.first?.value)
        XCTAssertEqual(records[1].context.observations.captureConditions,f.input.captureConditions)
        XCTAssertEqual(records[1].currentInput?.stamp,stamp(1))
        let decisions = try DecisionReplay.evaluate(records,model:f.model.compiled)
        XCTAssertEqual(decisions[0].controls.parameters.color.exposureEV,0)
        XCTAssertGreaterThan(decisions[1].controls.parameters.color.exposureEV,0)
    }
    func testGPUFailureResetsDecisionHistory() async throws {
        let f = try await fixture(); let live = SessionRenderDriver.live(f.renderer); let once = SessionTestOnce()
        let driver = SessionRenderDriver(observe:live.observe,submit:{ input,plan,requirements,beforeCommit in
            let submitted = try live.submit(input,plan,requirements,beforeCommit)
            guard once.take() else { return submitted }
            return SessionSubmission(completion:{
                _ = try await submitted.value()
                throw SessionTestFailure.injectedGPUFailure
            })
        })
        let session = try CameraSession(model:f.model,driver:driver)
        do { _ = try await session.enqueue(f.input,stamp:stamp(5)); XCTFail("Injected GPU failure was hidden") }
        catch SessionTestFailure.injectedGPUFailure { }
        let failedRecords = await session.takeRecords()
        XCTAssertEqual(failedRecords.map { $0.context.evaluationStamp.index },[5])
        assertRendered(try await session.enqueue(f.input,stamp:stamp(1,generation:1)),stamp:stamp(1,generation:1))
        let restarted = await session.takeRecords()
        XCTAssertEqual(restarted.first?.event,.reset(.gpuFailure))
        let decisions = try DecisionReplay.evaluate(restarted,model:f.model.compiled)
        let record = try XCTUnwrap(restarted.first)
        let raw = try CameraModelEvaluator.evaluate(f.model.compiled,context:record.context)
        XCTAssertEqual(decisions[0].controls.parameters.color.exposureEV,raw.parameters.color.exposureEV)
    }
    func testExplicitResetIgnoresLateCompletionAndItsObservation() async throws {
        let f = try await fixture(delayed:true); let gate = SessionTestGate()
        let live = SessionRenderDriver.live(f.renderer); let once = SessionTestOnce()
        let driver = SessionRenderDriver(observe:live.observe,submit:{ input,plan,requirements,beforeCommit in
            let submitted = try live.submit(input,plan,requirements,beforeCommit)
            guard once.take() else { return submitted }
            return SessionSubmission(completion:{
                let result = try await submitted.value()
                await gate.enter()
                return result
            })
        })
        let session = try CameraSession(model:f.model,driver:driver)
        let first = Task { try await session.enqueue(f.input,stamp:self.stamp(5)) }
        await gate.waitForArrival()
        try await session.reset(.reset(.seek)); await gate.release()
        let late = try await first.value
        guard case .dropped(let droppedStamp,.reset) = late else { return XCTFail("Late old-generation completion published") }
        XCTAssertEqual(droppedStamp,stamp(5))
        _ = await session.takeRecords()
        assertRendered(try await session.enqueue(f.input,stamp:stamp(1,generation:1)),stamp:stamp(1,generation:1))
        let restarted = await session.takeRecords()
        XCTAssertEqual(restarted.first?.event,.reset(.seek))
        // The late completion's feature packet must not warm the new generation.
        XCTAssertNil(restarted.first?.context.observations.features.first?.value)
        XCTAssertEqual(restarted.first?.context.observations.stamp,stamp(1,generation:1))
    }
    func testPendingResetCannotBeOverwrittenByLockEvent() async throws {
        let f = try await fixture(); let session = try CameraSession(renderer:f.renderer,model:f.model)
        assertRendered(try await session.enqueue(f.input,stamp:stamp(5)),stamp:stamp(5))
        _ = await session.takeRecords()
        try await session.reset(.reset(.seek))
        let lock = ControlOverride(target:"color.exposureEV",value:.scalar(0.7))
        do {
            _ = try await session.enqueue(f.input,stamp:stamp(1,generation:1),event:.lock([lock]))
            XCTFail("Lock event overwrote the pending reset")
        } catch { }
        assertRendered(try await session.enqueue(f.input,stamp:stamp(2,generation:1)),stamp:stamp(2,generation:1))
        let records = await session.takeRecords()
        XCTAssertEqual(records.count,1)
        XCTAssertEqual(records.first?.event,.reset(.seek))
        XCTAssertNoThrow(try DecisionReplay.evaluate(records,model:f.model.compiled))
    }
    func waitForWaitingCount(_ expected:Int, session:CameraSession) async -> Bool {
        // Poll actor state, yielding cooperatively; never assume a GPU or wall-clock delay.
        for _ in 0..<10000 {
            if await session.queueSnapshot().waiting == expected { return true }
            await Task.yield()
        }
        return false
    }
    func testWaitQueueIsBoundedAndAcceptedFramesStayOrdered() async throws {
        let f = try await fixture(maxFrames:1); let gate = SessionTestGate(); let live = SessionRenderDriver.live(f.renderer)
        let driver = SessionRenderDriver(observe:{ input,stamp,requirements,bytes in
            await gate.enter(); return try await live.observe(input,stamp,requirements,bytes)
        },submit:live.submit)
        let session = try CameraSession(model:f.model,backpressure:.wait,driver:driver)
        let first = Task { self.assertRendered(try await session.enqueue(f.input,stamp:self.stamp(1)),stamp:self.stamp(1)) }
        await gate.waitForArrival()
        let second = Task { self.assertRendered(try await session.enqueue(f.input,stamp:self.stamp(2)),stamp:self.stamp(2)) }
        guard await waitForWaitingCount(1,session:session) else {
            await gate.release(); _ = try? await first.value; _ = try? await second.value
            return XCTFail("Second request did not enter bounded waiting queue")
        }
        let before = await session.queueSnapshot()
        XCTAssertEqual(before.active,1); XCTAssertEqual(before.pending,0); XCTAssertEqual(before.waiting,1)
        do { _ = try await session.enqueue(f.input,stamp:stamp(3)); XCTFail("Unbounded waiting producer accepted") } catch { }
        let after = await session.queueSnapshot()
        XCTAssertEqual(after.active + after.pending,1); XCTAssertEqual(after.waiting,1)
        await gate.release(); try await first.value; try await second.value
        let records = await session.takeRecords()
        XCTAssertEqual(records.map { $0.context.evaluationStamp.index },[1,2])
        XCTAssertNoThrow(try DecisionReplay.evaluate(records,model:f.model.compiled))
    }
    func testCancelledAdmissionWaiterDoesNotSubmitOrRecord() async throws {
        let f = try await fixture(maxFrames:1); let gate = SessionTestGate(); let live = SessionRenderDriver.live(f.renderer)
        let driver = SessionRenderDriver(observe:{ input,stamp,requirements,bytes in
            await gate.enter(); return try await live.observe(input,stamp,requirements,bytes)
        },submit:live.submit)
        let session = try CameraSession(model:f.model,backpressure:.wait,driver:driver)
        let first = Task { self.assertRendered(try await session.enqueue(f.input,stamp:self.stamp(1)),stamp:self.stamp(1)) }
        await gate.waitForArrival()
        let second = Task { try await session.enqueue(f.input,stamp:self.stamp(2)) }
        guard await waitForWaitingCount(1,session:session) else {
            await gate.release(); _ = try? await first.value; _ = try? await second.value
            return XCTFail("Waiter was not admitted to waiting queue")
        }
        second.cancel(); await gate.release(); try await first.value
        let cancelled = try await second.value
        guard case .dropped(let cancelledStamp,.cancelled) = cancelled else { return XCTFail("Cancelled waiter submitted") }
        XCTAssertEqual(cancelledStamp,stamp(2))
        let records = await session.takeRecords()
        XCTAssertEqual(records.map { $0.context.evaluationStamp.index },[1])
        let idle = await session.queueSnapshot()
        XCTAssertEqual(idle.active + idle.pending + idle.waiting,0)
        assertRendered(try await session.enqueue(f.input,stamp:stamp(3)),stamp:stamp(3))
    }
    func testObservationGPUFailureResetsBeforeAnotherSourceStamp() async throws {
        let f = try await fixture(), live = SessionRenderDriver.live(f.renderer), once = SessionTestOnce()
        let driver = SessionRenderDriver(observe: { input, stamp, requirements, bytes in
            if once.take() { throw ModelGPUFailure(message: "injected statistics failure") }
            return try await live.observe(input, stamp, requirements, bytes)
        }, submit: live.submit)
        let session = try CameraSession(model: f.model, driver: driver)
        do { _ = try await session.enqueue(f.input, stamp: stamp(5)); XCTFail("GPU failure ignored") } catch { }
        assertRendered(try await session.enqueue(f.input, stamp: stamp(0)), stamp: stamp(0))
        let records = await session.takeRecords()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.event, .reset(.gpuFailure))
    }

    func testCancelledWaiterFreesCapacityBeforeActiveFrameCompletes() async throws {
        let f = try await fixture(maxFrames: 1), gate = SessionTestGate(), live = SessionRenderDriver.live(f.renderer)
        let driver = SessionRenderDriver(observe: { input, stamp, requirements, bytes in
            await gate.enter(); return try await live.observe(input, stamp, requirements, bytes)
        }, submit: live.submit)
        let session = try CameraSession(model: f.model, backpressure: .wait, driver: driver)
        let first = Task { try await session.enqueue(f.input, stamp: self.stamp(1)) }
        await gate.waitForArrival()
        let second = Task { try await session.enqueue(f.input, stamp: self.stamp(2)) }
        guard await waitForWaitingCount(1, session: session) else {
            await gate.release(); _ = try? await first.value; _ = try? await second.value
            return XCTFail("Waiter not enqueued")
        }
        let finished = expectation(description: "Cancelled waiter completes independently")
        let monitor = Task { _ = try? await second.value; finished.fulfill() }
        second.cancel()
        await fulfillment(of: [finished], timeout: 1)
        let state = await session.queueSnapshot()
        XCTAssertEqual(state.active, 1); XCTAssertEqual(state.waiting, 0)
        await gate.release(); _ = try await first.value; await monitor.value
        guard case .dropped(_, .cancelled) = try await second.value else { return XCTFail("Cancelled waiter rendered") }
    }

}
