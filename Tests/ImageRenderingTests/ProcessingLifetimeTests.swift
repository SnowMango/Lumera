import XCTest
import Metal
import CoreImage
import ImagingCore
@testable import ImageRendering

final class ProcessingLifetimeTests: XCTestCase {
    private func request(_ renderer: LumeraRenderer, width: Int = 31) throws -> PreparedProcessingRequest {
        let style = try renderer.prepare(ResolvedStyle(parameters: .init()))
        return try .init(renderer: renderer, style: style, input: .init(width: width, height: 17))
    }
    private func prepared(_ resources: ProcessingResources, _ request: PreparedProcessingRequest) throws {
        switch resources.prepare(request) {
        case .ready: break
        case .wouldBlock(let issue): throw issue
        case .failure(let error): throw error
        }
    }
    private func acquire(_ resources: ProcessingResources, _ request: PreparedProcessingRequest) throws -> FrameResources {
        switch resources.acquireFrame(for: request) {
        case .ready(let frame): return frame
        case .unavailable(let issue): throw issue
        }
    }
    func testSmallIdlePreferenceFitsPreparedSetAndReusesForThousandFrames() throws {
        let renderer = try LumeraRenderer(), request = try request(renderer)
        let resources = ProcessingResources(device: renderer.device,
            policy: .init(maxResidentBytes: 1, maxIdleBytes: 1, maxPendingFrames: 0))
        try prepared(resources, request)
        let before = resources.snapshot()
        XCTAssertGreaterThan(before.effectivePolicy.maxIdleBytes, 1)
        XCTAssertLessThanOrEqual(before.residentBytes, 256 * 1024 * 1024)
        for _ in 0..<1000 {
            try autoreleasepool { _ = try acquire(resources, request) }
        }
        XCTAssertEqual(resources.snapshot().allocationCount, before.allocationCount)
        XCTAssertEqual(resources.snapshot().activeFrames, 0)
        XCTAssertEqual(resources.snapshot().residentBytes, before.residentBytes)
    }
    func testTextureViewsCountOnceAndKeepRetiredStorageCharged() throws {
        let renderer = try LumeraRenderer(), request = try request(renderer)
        let resources = ProcessingResources(device: renderer.device, policy: .init(maxPendingFrames: 0))
        try prepared(resources, request)
        var held: MTLTexture?
        try autoreleasepool {
            let frame = try acquire(resources, request)
            held = frame.outputTexture
            let original = resources.snapshot().residentBytes
            let charge = try resources.ledger.borrow(frame.outputTexture)
            let view = try XCTUnwrap(frame.outputTexture.makeTextureView(pixelFormat: .rgba16Float))
            let duplicate = try resources.ledger.borrow(view)
            XCTAssertTrue(charge === duplicate)
            XCTAssertEqual(original, resources.snapshot().residentBytes)
        }
        resources.close()
        XCTAssertGreaterThan(resources.snapshot().residentBytes, 0)
        held = nil
        XCTAssertNil(held)
        XCTAssertEqual(resources.snapshot().residentBytes, 0)
    }
    func testEscapingSecondaryViewKeepsStorageUnavailable() throws {
        let renderer = try LumeraRenderer(), request = try request(renderer)
        let resources = ProcessingResources(device: renderer.device, policy: .init(maxPendingFrames: 0))
        try prepared(resources, request)
        var held: MTLTexture?
        try autoreleasepool {
            let frame = try acquire(resources, request)
            held = try XCTUnwrap(frame.outputTexture.makeTextureView(pixelFormat: .rgba16Float))
        }
        resources.close()
        XCTAssertGreaterThan(resources.snapshot().residentBytes, 0)
        held = nil
        XCTAssertNil(held)
        XCTAssertEqual(resources.snapshot().residentBytes, 0)
    }
    func testHeldOldGenerationAndTwoStreamsShareHardCeiling() throws {
        let renderer = try LumeraRenderer(), request = try request(renderer)
        let first = ProcessingResources(device: renderer.device,
            limits: .init(maxResidentBytes: 128 * 1024), policy: .init(maxPendingFrames: 0))
        let second = first.makeStreamResources()
        try prepared(first, request)
        let frame = try acquire(first, request)
        first.clearIdleResources()
        let held = first.snapshot().residentBytes
        try prepared(second, request)
        XCTAssertGreaterThan(second.snapshot().residentBytes, held)
        XCTAssertLessThanOrEqual(second.snapshot().residentBytes, 128 * 1024)
        first.updatePolicy(.init(maxResidentBytes: 1, maxIdleBytes: 0, maxPendingFrames: 0))
        XCTAssertTrue(first.snapshot().isShrinking)
        XCTAssertEqual(second.snapshot().effectivePolicy.maxResidentBytes, 1)
        withExtendedLifetime(frame) {}
    }
    func testSlowCompletionRetainsSlotAndPendingCancellationCompletesOnce() throws {
        let delivery = DispatchQueue(label: "test.paused.delivery")
        delivery.suspend()
        let renderer = try LumeraRenderer(completionQueue: delivery), request = try request(renderer)
        let resources = ProcessingResources(device: renderer.device, policy: .init(maxInFlightFrames: 1, maxPendingFrames: 1))
        try prepared(resources, request)
        let first = try acquire(resources, request), second = try acquire(resources, request)
        let source = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 31, height: 17))
        let firstDone = expectation(description: "first"), secondDone = expectation(description: "cancelled")
        let output1 = try first.makeImageOutput(colorSpace: LumeraRenderer.sRGB)
        let output2 = try second.makeImageOutput(colorSpace: LumeraRenderer.sRGB)
        _ = renderer.processImage(source, output: output1, context: renderer.context, workspace: first.workspace, request: request) { _ in firstDone.fulfill() }
        let submitted = renderer.processImage(source, output: output2, context: renderer.context, workspace: second.workspace, request: request) { result in
            switch result { case .success: XCTFail("Expected cancellation"); case .failure(let error): XCTAssertTrue(error is CancellationError) }
            secondDone.fulfill()
        }
        guard case .accepted(let task) = submitted else { delivery.resume(); return XCTFail("Not admitted") }
        task.cancel()
        XCTAssertEqual(resources.snapshot().activeFrames, 2)
        guard case .unavailable = resources.acquireFrame(for: request) else { delivery.resume(); return XCTFail("Unbounded admission") }
        delivery.resume()
        wait(for: [firstDone, secondDone], timeout: 10)
    }
    func testRejectedWorkspaceDoesNotConsumeImageTarget() throws {
        let renderer = try LumeraRenderer(), request = try request(renderer)
        let resources = ProcessingResources(device: renderer.device)
        try prepared(resources, request)
        let frame = try acquire(resources, request), other = try acquire(resources, request)
        let target = try frame.makeImageOutput(colorSpace: LumeraRenderer.sRGB)
        XCTAssertTrue(frame.workspace.claim(for: request))
        let input = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 31, height: 17))
        let rejected = renderer.processImage(input, output: target, context: renderer.context, workspace: frame.workspace, request: request) { _ in XCTFail("Rejected callback") }
        guard case .notAccepted = rejected else { return XCTFail("Duplicate accepted") }
        let done = expectation(description: "valid claim")
        let accepted = renderer.processImage(input, output: target, context: renderer.context, workspace: other.workspace, request: request) { result in
            if case .failure(let error) = result { XCTFail("\(error)") }; done.fulfill()
        }
        guard case .accepted = accepted else { return XCTFail("Target consumed on rejection") }
        wait(for: [done], timeout: 10)
    }
}
