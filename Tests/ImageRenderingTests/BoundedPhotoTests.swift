import XCTest
import CoreImage
import ImagingCore
@testable import ImageRendering

final class BoundedPhotoTests: XCTestCase {
    func testLazySourceCanPrepareRegionWithoutFullTexture() async throws {
        let renderer = try LumeraRenderer()
        let working = WorkingImageContract(referenceRenditionID: "region")
        var descriptor = SourceDescriptor(id: "region", path: .processedPhoto); descriptor.recipeID = "ci"
        let recipe = InputRecipe(id: "ci", backend: "coreImage", version: "1", decodedRendition: .baseImage)
        let execution = ExecutionProfile(width: 8000, height: 6000, budget: .init(maxInFlightFrames: 1, maxResidentBytes: 8 * 1024 * 1024))
        let adapter = try InputAdapter(renderer: renderer, working: working)
        let source = try adapter.resolve(.image(CIImage(color: CIColor(red: 0.3, green: 0.4, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 8000, height: 6000))), descriptor: descriptor, recipe: recipe, execution: execution)
        XCTAssertEqual(source.width, 8000)
        let input = try await source.prepare(region: CGRect(x: 400, y: 500, width: 32, height: 40), execution: execution)
        XCTAssertEqual(input.width, 32); XCTAssertEqual(input.height, 40)
        XCTAssertEqual(input.valueBounds.lower, 0.3, accuracy: 0.003)
    }
}

private final class SyntheticRegionProvider: PhotoRegionSource, @unchecked Sendable {
    let revision = UUID()
    let width: Int, height: Int
    let memory = PhotoSourceMemory(knownResidentBytes: 0, hasOpaqueDecoderMemory: false)
    let adapter: InputAdapter
    var requests = [CGRect]()
    init(width: Int, height: Int, renderer: LumeraRenderer) throws {
        self.width = width; self.height = height
        adapter = try InputAdapter(renderer: renderer, working: .init(referenceRenditionID: "region"))
    }
    func prepare(region: CGRect, execution: ExecutionProfile) async throws -> NormalizedInput {
        guard region.width < CGFloat(width) || region.height < CGFloat(height) else { throw LabError.invalid("Full-frame request refused") }
        requests.append(region)
        var descriptor = SourceDescriptor(id: "region", path: .processedPhoto); descriptor.recipeID = "ci"
        let recipe = InputRecipe(id: "ci", backend: "coreImage", version: "1", decodedRendition: .baseImage)
        let image = CIImage(color: CIColor(red: 0.3, green: 0.4, blue: 0.5)).cropped(to: region)
        return try await adapter.prepare(.image(image), descriptor: descriptor, recipe: recipe, execution: execution)
    }
}

extension BoundedPhotoTests {
    func testStreamingRejectsFullFrameProviderRequestsAndPreservesStatistics() async throws {
        let renderer = try LumeraRenderer()
        let provider = try SyntheticRegionProvider(width: 701, height: 509, renderer: renderer)
        var definition = StyleModel(identity: .init(id: "stream", name: "manual"))
        definition.observations.features = [.init(id: "red", statistic: .meanRed)]
        let execution = ExecutionProfile(width: 701, height: 509, budget: .init(maxInFlightFrames: 1, maxResidentBytes: 8 * 1024 * 1024))
        let model = try ModelPreparer(renderer: renderer).prepareStreaming(StyleModelCompiler.compile(definition), resources: .init(), execution: execution)
        XCTAssertThrowsError(try model.reserveFrame())
        let stamp = FrameStamp(streamID: "stream", generation: 0, index: 1, presentationTime: 0, duration: 1)
        var count = 0
        let result = try await renderer.streamPhoto(provider, model: model, stamp: stamp) { tile in
            count += Int(tile.core.width * tile.core.height)
            let value = tile.bytes.load(as: Float16.self)
            XCTAssertEqual(Float(value), 0.3, accuracy: 0.003)
            await Task.yield()
        }
        XCTAssertEqual(count, 701 * 509)
        XCTAssertEqual(result.observations.features[0].value!, pow((0.3 + 0.055) / 1.055, 2.4), accuracy: 0.0002)
        XCTAssertLessThanOrEqual(result.peakKnownOwnedBytes, execution.budget.maxResidentBytes)
        XCTAssertFalse(result.hasOpaqueDecoderMemory)
    }
    func testLargePhotosStreamWithinBudgetWithoutFullFrameInput() async throws {
        for (w,h) in [(4000,3000),(8000,6000)] {
            let renderer = try LumeraRenderer()
            let provider = try SyntheticRegionProvider(width: w, height: h, renderer: renderer)
            let definition = StyleModel(identity: .init(id: "large-photo", name: "manual"))
            let execution = ExecutionProfile(width: w, height: h, budget: .init(maxInFlightFrames: 1, maxResidentBytes: 16 * 1024 * 1024))
            let model = try ModelPreparer(renderer: renderer).prepareStreaming(StyleModelCompiler.compile(definition), resources: .init(), execution: execution)
            var pixels = 0
            let result = try await renderer.streamPhoto(provider, model: model,
                stamp: .init(streamID: "large-photo", generation: 0, index: 1, presentationTime: 0, duration: 1)) { tile in pixels += Int(tile.core.width * tile.core.height) }
            XCTAssertEqual(pixels, w*h)
            XCTAssertLessThanOrEqual(result.peakKnownOwnedBytes, 16 * 1024 * 1024)
        }
    }
}

extension BoundedPhotoTests {
    func testNondivisibleGridMatchesWholeFrameAfterCalibration() async throws {
        let renderer = try LumeraRenderer()
        let working = WorkingImageContract(referenceRenditionID: "region")
        var descriptor = SourceDescriptor(id: "region", path: .processedPhoto); descriptor.recipeID = "ci"
        let recipe = InputRecipe(id: "ci", backend: "coreImage", version: "1", decodedRendition: .baseImage)
        let execution = ExecutionProfile(width: 701, height: 509, budget: .init(maxInFlightFrames: 1, maxResidentBytes: 64 * 1024 * 1024))
        let image = CIFilter(name: "CILinearGradient", parameters: ["inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 701, y: 509), "inputColor0": CIColor(red: 0.01, green: 0.2, blue: 0.6), "inputColor1": CIColor(red: 0.95, green: 0.6, blue: 0.1)])!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 701, height: 509))
        let source = try InputAdapter(renderer: renderer, working: working).resolve(.image(image), descriptor: descriptor, recipe: recipe, execution: execution)
        let normalized = try await source.prepare(region: source.bounds, execution: execution)
        var calibration = InputCalibration(id: "half", source: descriptor, working: working)
        calibration.recipeDigest = try normalized.effectiveRecipe.digest(); calibration.correction.matrix.values = [0.5,0,0,0,0.5,0,0,0,0.5]
        let normalizer = InputNormalizer(renderer: renderer), resources = try ModelResourceSet()
        let full = try await normalizer.normalize(normalized, calibration: calibration, resources: resources)
        var requirements = ObservationRequirements()
        requirements.features = [.init(id: "red", statistic: .meanRed), .init(id: "above", statistic: .fractionAbove(0.2)), .init(id: "below", statistic: .fractionBelow(0.1))]
        let stamp = FrameStamp(streamID: "grid", generation: 0, index: 1, presentationTime: 0, duration: 1)
        let expected = try await renderer.observe(full, stamp: stamp, requirements: requirements)
        let actual = try await renderer.observe(source, normalizer: normalizer, calibration: calibration, resources: resources, execution: execution, stamp: stamp, requirements: requirements)
        XCTAssertEqual(actual, expected)
    }
    func testSinkFailureAndCancellationReleaseReservation() async throws {
        let renderer = try LumeraRenderer()
        let provider = try SyntheticRegionProvider(width: 701, height: 509, renderer: renderer)
        let definition = StyleModel(identity: .init(id: "cancel", name: "manual"))
        let execution = ExecutionProfile(width: 701, height: 509, budget: .init(maxInFlightFrames: 1, maxResidentBytes: 8 * 1024 * 1024))
        let model = try ModelPreparer(renderer: renderer).prepareStreaming(StyleModelCompiler.compile(definition), resources: .init(), execution: execution)
        let stamp = FrameStamp(streamID: "cancel", generation: 0, index: 1, presentationTime: 0, duration: 1)
        for _ in 0..<2 {
            do { _ = try await renderer.streamPhoto(provider, model: model, stamp: stamp) { _ in throw CancellationError() }; XCTFail("Must abort") }
            catch is CancellationError {} // Second operation proves the first returned its reservation.
        }
        var count = 0
        _ = try await renderer.streamPhoto(provider, model: model, stamp: stamp) { tile in count += Int(tile.core.width * tile.core.height) }
        XCTAssertEqual(count, 701 * 509)
        let input = try await provider.prepare(region: CGRect(x: 0, y: 0, width: 32, height: 32), execution: execution)
        var parameters = StyleParameters(); parameters.color.exposureEV = 1
        let style = try renderer.prepare(ResolvedStyle(parameters: parameters)), command = renderer.queue.makeCommandBuffer()!
        _ = try renderer.encoder.encode(input.texture, style: style, request: .init(input: .init(width: 32, height: 32)), commandBuffer: command)
        try await renderer.complete(command)
        XCTAssertGreaterThan(renderer.encoder.cachedTextureBytes, 0, "Cancelled streams must release bounded isolation")
    }
}

extension BoundedPhotoTests {
    func testUnknownHalfOverflowRejectedDuringRegionPreflight() async throws {
        let renderer = try LumeraRenderer()
        var descriptor = SourceDescriptor(id: "range", path: .processedPhoto); descriptor.recipeID = "ci"
        let recipe = InputRecipe(id: "ci", backend: "coreImage", version: "1", decodedRendition: .baseImage)
        var working = WorkingImageContract(referenceRenditionID: "region"); working.dynamicRange = .edr
        var execution = ExecutionProfile(width: 4, height: 4, budget: .init(maxInFlightFrames: 1, maxResidentBytes: 8 * 1024 * 1024)); execution.dynamicRange = .edr
        let values: [Float] = (0..<16).flatMap { _ in [100000, 1, 1, 1] }
        let image = CIImage(bitmapData: values.withUnsafeBytes { Data($0) }, bytesPerRow: 64, size: .init(width: 4, height: 4), format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedSRGB))
        let source = try InputAdapter(renderer: renderer, working: working).resolve(.image(image), descriptor: descriptor, recipe: recipe, execution: execution)
        do { _ = try await source.prepare(region: CGRect(x: 0, y: 0, width: 2, height: 2), execution: execution); XCTFail("Unsafe narrow write") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Float16") || error.localizedDescription.contains("half"), "\(error)") }
    }
}

extension BoundedPhotoTests {
    func testBoundedScopePurgesIdlePoolAndRejectsUnbudgetedEncoding() async throws {
        let renderer = try LumeraRenderer()
        let provider = try SyntheticRegionProvider(width: 64, height: 64, renderer: renderer)
        let execution = ExecutionProfile(width: 64, height: 64, budget: .init(maxInFlightFrames: 1, maxResidentBytes: 8 * 1024 * 1024))
        let input = try await provider.prepare(region: CGRect(x: 0, y: 0, width: 32, height: 32), execution: execution)
        var p = StyleParameters(); p.color.exposureEV = 1
        let style = try renderer.prepare(ResolvedStyle(parameters: p))
        let request = RenderRequest(input: .init(width: 32, height: 32))
        let command = renderer.queue.makeCommandBuffer()!
        _ = try renderer.encoder.encode(input.texture, style: style, request: request, commandBuffer: command)
        XCTAssertThrowsError(try renderer.encoder.beginBoundedPhotoWork())
        try await renderer.complete(command)
        XCTAssertGreaterThan(renderer.encoder.cachedTextureBytes, 0)
        let scope = try renderer.encoder.beginBoundedPhotoWork()
        XCTAssertEqual(renderer.encoder.cachedTextureBytes, 0)
        let other = renderer.queue.makeCommandBuffer()!
        XCTAssertThrowsError(try renderer.encoder.encode(input.texture, style: style, request: request, commandBuffer: other))
        scope.finish()
        _ = try renderer.encoder.encode(input.texture, style: style, request: request, commandBuffer: other)
        try await renderer.complete(other)
    }
}

extension BoundedPhotoTests {
    func testConcurrentStreamsShareCeilingAndReleaseIsolation() async throws {
        let renderer = try LumeraRenderer()
        let a = try SyntheticRegionProvider(width: 701, height: 509, renderer: renderer)
        let b = try SyntheticRegionProvider(width: 701, height: 509, renderer: renderer)
        let definition = StyleModel(identity: .init(id: "concurrent", name: "manual"))
        let execution = ExecutionProfile(width: 701, height: 509, budget: .init(maxInFlightFrames: 2, maxResidentBytes: 16 * 1024 * 1024))
        let model = try ModelPreparer(renderer: renderer).prepareStreaming(StyleModelCompiler.compile(definition), resources: .init(), execution: execution)
        let stamp = FrameStamp(streamID: "concurrent", generation: 0, index: 1, presentationTime: 0, duration: 1)
        async let first = renderer.streamPhoto(a, model: model, stamp: stamp) { _ in await Task.yield() }
        async let second = renderer.streamPhoto(b, model: model, stamp: stamp) { _ in await Task.yield() }
        let results = try await (first, second)
        XCTAssertEqual(results.0.peakKnownOwnedBytes, execution.budget.maxResidentBytes)
        XCTAssertEqual(results.1.peakKnownOwnedBytes, execution.budget.maxResidentBytes)
        XCTAssertEqual(renderer.encoder.cachedTextureBytes, 0)
        let scope = try renderer.encoder.beginBoundedPhotoWork(); scope.finish()
    }
    func testDiscardedPooledCommandDoesNotLeaveStickyIsolationBlock() async throws {
        let renderer = try LumeraRenderer()
        let provider = try SyntheticRegionProvider(width: 64, height: 64, renderer: renderer)
        let execution = ExecutionProfile(width: 64, height: 64, budget: .init(maxInFlightFrames: 1, maxResidentBytes: 8 * 1024 * 1024))
        let input = try await provider.prepare(region: CGRect(x: 0, y: 0, width: 32, height: 32), execution: execution)
        var parameters = StyleParameters(); parameters.color.exposureEV = 1
        let style = try renderer.prepare(ResolvedStyle(parameters: parameters))
        try autoreleasepool {
            let command = renderer.queue.makeCommandBuffer()!
            _ = try renderer.encoder.encode(input.texture, style: style, request: .init(input: .init(width: 32, height: 32)), commandBuffer: command)
            XCTAssertThrowsError(try renderer.encoder.beginBoundedPhotoWork())
        }
        let scope = try renderer.encoder.beginBoundedPhotoWork(); scope.finish()
    }
}
