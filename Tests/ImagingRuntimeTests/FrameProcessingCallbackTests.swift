import XCTest
import CoreImage
import ImagingCore
import ImageRendering
@testable import ImagingRuntime

final class FrameProcessingCallbackTests: XCTestCase {
    func testIdentityWithDelayedStatisticsUsesInputStorageWithoutNewPixelAllocations() async throws {
        let fixture = try await FrameProcessingSessionTests().fixture(maxFrames: 1, delayed: true)
        let renderer = fixture.renderer, model = fixture.model
        let resources = ProcessingResources(device: renderer.device, policy: .init(maxPendingFrames: 0))
        let source = fixture.input.source
        let preparer = try model.prepareRealtimeInput(working: source.working)
        let configured = try preparer.explicitInput(descriptor: source.descriptor, recipe: source.effectiveRecipe.declared,
            normalizedRGBBounds: .init(lower: 0, upper: 1), resources: resources.makeStreamResources())
        switch configured.prepare() {
        case .ready: break
        case .wouldBlock(let issue): throw issue
        case .failure(let error): throw error
        }
        let before = resources.snapshot().allocationCount
        let session = try FrameProcessingSession(renderer: renderer, model: model,
            resources: ModelProcessingResources(resources: resources.makeStreamResources()))
        let context = CIContext(mtlDevice: renderer.device)
        let image = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
        let input = FrameSource(.image(image), using: configured, context: context)
        let outcome = try await session.enqueue(input, stamp: .init(streamID: "delayed", generation: 0, index: 0, presentationTime: 0, duration: 1/30))
        guard case .rendered(let frame) = outcome else { return XCTFail("Dropped") }
        XCTAssertEqual(frame.resolvedControls.parameters.color.exposureEV, 0)
        XCTAssertEqual(resources.snapshot().allocationCount, before)
        var pixel = [Float](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { context.render(frame.image, toBitmap: $0.baseAddress!, rowBytes: 16,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) }
        XCTAssertEqual(pixel[0], 0.5, accuracy: 0.003)
    }
    func testExplicitInputAndCallbackMatchAsyncDecisionAndPixels() async throws {
        let fixture = try await FrameProcessingSessionTests().fixture(maxFrames: 2)
        let renderer = fixture.renderer, model = fixture.model
        let resources = ProcessingResources(device: renderer.device, policy: .init(maxPendingFrames: 0))
        let source = fixture.input.source
        let preparer = try model.prepareRealtimeInput(working: source.working)
        let input = try preparer.explicitInput(descriptor: source.descriptor, recipe: source.effectiveRecipe.declared,
            normalizedRGBBounds: .init(lower: 0, upper: 1), resources: resources.makeStreamResources())
        switch input.prepare() {
        case .ready: break
        case .wouldBlock(let issue): throw issue
        case .failure(let error): throw error
        }
        let session = try FrameProcessingSession(renderer: renderer, model: model,
            resources: ModelProcessingResources(resources: resources.makeStreamResources()))
        let image = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
        let context = CIContext(mtlDevice: renderer.device)
        var allocationCount: Int?
        for index in 0..<8 {
            let stamp = FrameStamp(streamID: "callback", generation: 0, index: UInt64(index), presentationTime: Double(index) / 30, duration: 1 / 30)
            let outcome: FrameOutcome = try await withCheckedThrowingContinuation { continuation in
                do {
                    let prepared = try input.makeInput(.image(image), context: context)
                    try session.enqueue(prepared, stamp: stamp) { continuation.resume(with: $0) }
                } catch { continuation.resume(throwing: error) }
            }
            guard case .rendered(let frame) = outcome else { return XCTFail("Dropped") }
            XCTAssertEqual(frame.width, 4); XCTAssertEqual(frame.height, 4)
            XCTAssertEqual(frame.resolvedControls.automatic.sourceID, fixture.input.sourceID)
            var pixel = [Float](repeating: 0, count: 4)
            pixel.withUnsafeMutableBytes { context.render(frame.image, toBitmap: $0.baseAddress!, rowBytes: 16,
                bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) }
            XCTAssertGreaterThan(pixel[0], 0.5)
            let current = resources.snapshot().allocationCount
            if let allocationCount { XCTAssertEqual(current, allocationCount) }
            else { allocationCount = current }
        }
        let records = await session.takeRecords()
        XCTAssertEqual(records.count, 8)
        let replay = try DecisionReplay.evaluate(records, model: model.compiled)
        XCTAssertEqual(replay.map(\.sourceFrameIndex), Array(0..<8).map(UInt64.init))
    }
}
