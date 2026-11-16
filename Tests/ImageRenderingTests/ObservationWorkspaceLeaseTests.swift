import XCTest
import CoreImage
import Metal
import ImagingCore
@testable import ImageRendering

final class ObservationWorkspaceLeaseTests: XCTestCase {
    func testHeldReadbackOwnsStatisticsUntilReleaseAndRejectsConcurrentReuse() async throws {
        let renderer = try LumeraRenderer()
        let working = WorkingImageContract(referenceRenditionID: "observation-lease")
        let execution = ExecutionProfile(width: 4, height: 4, budget: .init(maxInFlightFrames: 1, maxResidentBytes: 16 * 1024 * 1024))
        let recipe = InputRecipe(id: "ci", backend: "coreImage", version: "1", decodedRendition: .baseImage)
        var descriptor = SourceDescriptor(id: "test", path: .processedPhoto); descriptor.recipeID = recipe.id
        let image = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
        let source = try await InputAdapter(renderer: renderer, working: working).prepare(.image(image), descriptor: descriptor, recipe: recipe, execution: execution)
        let input = try await InputNormalizer(renderer: renderer).normalize(source, calibration: nil, resources: .init())
        var requirements = ObservationRequirements(); requirements.features = [.init(id: "mean", statistic: .meanGreen)]
        let ledger = ProcessingResourceLedger(limits: .init(), policy: .init())
        input.observationWorkspace = try PreparedObservationWorkspace(device: renderer.device, width: 4, height: 4, requirements: requirements, ledger: ledger)
        let extractor = try FrameFeatureExtractor(device: renderer.device)
        let stamp = FrameStamp(streamID: "stats", generation: 0, index: 0, presentationTime: 0, duration: 1/30)
        let command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
        var readback: ObservationReadback? = try extractor.encode(input, stamp: stamp, requirements: requirements, commandBuffer: command)
        try await renderer.complete(command)
        let next = try XCTUnwrap(renderer.queue.makeCommandBuffer())
        XCTAssertThrowsError(try extractor.encode(input, stamp: stamp, requirements: requirements, commandBuffer: next))
        let result = try XCTUnwrap(readback).resolve()
        XCTAssertEqual(try XCTUnwrap(result.features.first?.value), 0.214, accuracy: 0.002)
        let allocationCount = ledger.allocationCount
        readback = nil
        let nextReadback = try extractor.encode(input, stamp: stamp, requirements: requirements, commandBuffer: next)
        try await renderer.complete(next)
        XCTAssertEqual(try XCTUnwrap(nextReadback.resolve().features.first?.value), 0.214, accuracy: 0.002)
        XCTAssertEqual(ledger.allocationCount, allocationCount)
    }
}
