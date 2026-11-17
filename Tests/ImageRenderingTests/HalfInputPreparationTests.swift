import XCTest
import CoreImage
import Metal
import ImagingCore
@testable import ImageRendering

final class HalfInputPreparationTests: XCTestCase {
    func testPooledInputAdmissionCountsBackingPixelsOnce() async throws {
        let renderer = try LumeraRenderer()
        let resources = ProcessingResources(device: renderer.device)
        let adapter = try InputAdapter(renderer: renderer, working: .init(referenceRenditionID: "pool-test"))
        var descriptor = SourceDescriptor(id: "pool-test", path: .processedPhoto); descriptor.recipeID = "ci"
        let recipe = InputRecipe(id: "ci", backend: "coreImage", version: "1", decodedRendition: .baseImage)
        let execution = ExecutionProfile(width: 16, height: 16,
            budget: .init(maxInFlightFrames: 1, maxResidentBytes: 64 * 1024))
        let image = CIImage(color: CIColor(red: 0.3, green: 0.3, blue: 0.3))
            .cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
        let normalized = try await adapter.prepare(.image(image), descriptor: descriptor, recipe: recipe,
            execution: execution, rawOverrides: [], rawConfiguration: nil, trustedNormalizedRGBBounds: nil,
            resources: resources)
        let prepared = try await InputNormalizer(renderer: renderer).normalize(normalized, calibration: nil, resources: .init())
        let backing = try XCTUnwrap(normalized.texture.parent)
        XCTAssertEqual(prepared.residentStorageBytes, backing.allocatedSize)
        XCTAssertLessThanOrEqual(prepared.residentStorageBytes, execution.budget.maxResidentBytes)
    }

    func testCallerPoolReusesStagingWhileRetainingPreviousOutput() async throws {
        let renderer = try LumeraRenderer()
        let owner = ProcessingResources(device: renderer.device)
        let bounds = CGRect(x: 0, y: 0, width: 16, height: 16)
        let space = CGColorSpace(name: CGColorSpace.extendedSRGB)!
        let bright = CIImage(color: CIColor(red: 1.5, green: 0.5, blue: 0.25, alpha: 1,
                                          colorSpace: space)!).cropped(to: bounds)
        let first = try await renderer.prepareHalfInput(bright, bounds: bounds, colorSpace: space,
            budget: 8 * 1024 * 1024, resources: owner)
        let before = try await pixels(first.texture, renderer: renderer)
        XCTAssertEqual(owner.snapshot().allocationCount, 2)
        let second = try await renderer.prepareHalfInput(CIImage(color: .black).cropped(to: bounds),
            bounds: bounds, colorSpace: space, budget: 8 * 1024 * 1024, resources: owner)
        XCTAssertEqual(owner.snapshot().allocationCount, 3, "Reuse staging; acquire only a new leased destination")
        XCTAssertFalse(first.texture.parent === second.texture.parent)
        let preserved = try await pixels(first.texture, renderer: renderer)
        XCTAssertEqual(preserved, before)
    }

    private func texture(_ device: MTLDevice, _ format: MTLPixelFormat, _ w: Int, _ h: Int) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
        d.storageMode = .shared; d.usage = [.shaderRead, .shaderWrite]
        return try XCTUnwrap(device.makeTexture(descriptor: d))
    }
    private func pixels(_ texture: MTLTexture, renderer: LumeraRenderer) async throws -> [Float16] {
        let copy = try self.texture(renderer.device, .rgba16Float, texture.width, texture.height)
        let command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
        let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
        blit.copy(from: texture, to: copy); blit.endEncoding(); try await renderer.complete(command)
        var values = [Float16](repeating: 0, count: texture.width * texture.height * 4)
        values.withUnsafeMutableBytes { copy.getBytes($0.baseAddress!, bytesPerRow: texture.width * 8,
            from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0) }
        return values
    }
    func testFusedRangeMatchesStoredHalfAtOddEdgesWithoutClipping() async throws {
        let renderer = try LumeraRenderer(), w = 513, h = 259
        let input = try texture(renderer.device, .rgba32Float, w, h)
        let output = try texture(renderer.device, .rgba16Float, w, h)
        var source = [SIMD4<Float>](repeating: .init(0.3, 0.25, 0.7, 1), count: w * h)
        source[0] = .init(-2, 4, 0.3, 0.125)
        source[source.count - 1] = .init(12, -3, 0.1, 0.5)
        source.withUnsafeBytes { input.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
            withBytes: $0.baseAddress!, bytesPerRow: w * 16) }
        let command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
        let workspace = TileWorkingSet(limit: renderer.rangeReducer.estimatedBytes(width: w, height: h))
        let ticket = try renderer.rangeReducer.encodeHalfPreparation(input, output: output, commandBuffer: command, workingSet: workspace)
        XCTAssertThrowsError(try ticket.resolve())
        try await renderer.complete(command)
        let range = try ticket.resolve(), stored = try await pixels(output, renderer: renderer)
        XCTAssertEqual(range, .init(lower: -3, upper: 12))
        for i in source.indices { for c in 0..<4 {
            XCTAssertEqual(stored[i * 4 + c], Float16(source[i][c]))
            if c < 3 { XCTAssertTrue(range.contains(Double(stored[i * 4 + c]))) }
        } }
        XCTAssertLessThanOrEqual(workspace.bytes, workspace.limit)
    }
    func testPartialTileUsesValidExtentAndDestinationOrigin() async throws {
        let renderer = try LumeraRenderer()
        let input = try texture(renderer.device, .rgba32Float, 17, 19)
        let output = try texture(renderer.device, .rgba16Float, 7, 9)
        var source = [SIMD4<Float>](repeating: .init(.nan, .infinity, 0, 1), count: 17 * 19)
        for y in 0..<5 { for x in 0..<3 { source[y * 17 + x] = .init(-2, 4, 0.25, 1) } }
        source.withUnsafeBytes { input.replace(region: MTLRegionMake2D(0, 0, 17, 19), mipmapLevel: 0,
            withBytes: $0.baseAddress!, bytesPerRow: 17 * 16) }
        let untouched = [Float16](repeating: -9, count: 7 * 9 * 4)
        untouched.withUnsafeBytes { output.replace(region: MTLRegionMake2D(0, 0, 7, 9), mipmapLevel: 0,
            withBytes: $0.baseAddress!, bytesPerRow: 7 * 8) }
        let command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
        let ticket = try renderer.rangeReducer.encodeHalfPreparation(input, output: output, commandBuffer: command,
            workingSet: TileWorkingSet(limit: 1024 * 1024), width: 3, height: 5, outputOrigin: .init(4, 4))
        try await renderer.complete(command)
        XCTAssertEqual(try ticket.resolve(), .init(lower: -2, upper: 4))
        let stored = try await pixels(output, renderer: renderer)
        for y in 0..<9 { for x in 0..<7 {
            XCTAssertEqual(stored[(y * 7 + x) * 4], x >= 4 && y >= 4 ? -2 : -9)
        } }
    }
    func testInputValidationRejectsEveryNonfiniteChannelAndHalfOverflow() async throws {
        let renderer = try LumeraRenderer(), w = 33, h = 17
        let input = try texture(renderer.device, .rgba32Float, w, h)
        let output = try texture(renderer.device, .rgba16Float, w, h)
        for channel in 0..<4 { for invalid in [Float.nan, .infinity, -.infinity, 100_000] {
            var source = [SIMD4<Float>](repeating: .init(0.5, 0.5, 0.5, 1), count: w * h)
            source[source.count - 1][channel] = invalid
            source.withUnsafeBytes { input.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                withBytes: $0.baseAddress!, bytesPerRow: w * 16) }
            let command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
            let ticket = try renderer.rangeReducer.encodeHalfPreparation(input, output: output, commandBuffer: command,
                workingSet: TileWorkingSet(limit: 1024 * 1024))
            try await renderer.complete(command)
            XCTAssertThrowsError(try ticket.resolve(), "channel \(channel), value \(invalid)")
        } }
    }
    func testReusePreservesColorGeometryAndAlphaWithinHalfTolerance() async throws {
        let renderer = try LumeraRenderer(), w = 131, h = 69
        let source = (0..<(w * h)).map { i in SIMD4<Float>(Float(i % w) / Float(w) * 1.4,
            Float(i / w) / Float(h), -0.1, 0.5 + Float(i % 3) * 0.25) }
        let image = CIImage(bitmapData: source.withUnsafeBytes { Data($0) }, bytesPerRow: w * 16,
            size: .init(width: w, height: h), format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.displayP3))
            .transformed(by: .init(translationX: -7, y: 11))
        let colorSpace = CGColorSpace(name: CGColorSpace.extendedSRGB)!
        let reused = try await renderer.prepareHalfInput(image, bounds: image.extent, colorSpace: colorSpace, budget: 8 * 1024 * 1024)
        let reference = try texture(renderer.device, .rgba16Float, w, h)
        let command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
        renderer.context.render(image, to: reference, commandBuffer: command, bounds: image.extent, colorSpace: colorSpace)
        try await renderer.complete(command)
        let a = try await pixels(reused.texture, renderer: renderer), b = try await pixels(reference, renderer: renderer)
        var maxError = 0.0
        for i in a.indices {
            maxError = max(maxError, abs(Double(a[i]) - Double(b[i])))
            if i % 4 != 3 { XCTAssertTrue(reused.bounds.contains(Double(a[i]))) }
        }
        XCTAssertLessThanOrEqual(maxError, 0.004, "Destination precision may round differently, but must preserve colors and geometry")
        XCTAssertLessThan(reused.bounds.lower, 0)
        XCTAssertGreaterThan(reused.bounds.upper, 1)
        XCTAssertEqual(reused.texture.width, w); XCTAssertEqual(reused.texture.height, h)
        let tiled = try await renderer.prepareHalfInput(image, bounds: image.extent, colorSpace: colorSpace, budget: 160 * 1024)
        let tiledValues = try await pixels(tiled.texture, renderer: renderer)
        for i in a.indices { XCTAssertEqual(Double(tiledValues[i]), Double(a[i]), accuracy: 0.004) }
        XCTAssertEqual(tiled.bounds.lower, reused.bounds.lower, accuracy: 0.004)
        XCTAssertEqual(tiled.bounds.upper, reused.bounds.upper, accuracy: 0.004)
    }
    func testBudgetTilesWithoutRepeatedPreflightAndCancellationRejects() async throws {
        let renderer = try LumeraRenderer()
        let image = CIImage(color: CIColor(red: 0.3, green: 0.3, blue: 0.3)).cropped(to: .init(x: 0, y: 0, width: 512, height: 512))
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let tiled = try await renderer.prepareHalfInput(image, bounds: image.extent, colorSpace: space, budget: 3 * 1024 * 1024)
        let full = try await renderer.prepareHalfInput(image, bounds: image.extent, colorSpace: space, budget: 8 * 1024 * 1024)
        XCTAssertEqual(tiled.bounds, full.bounds)
        let tiledPixels = try await pixels(tiled.texture, renderer: renderer)
        let fullPixels = try await pixels(full.texture, renderer: renderer)
        XCTAssertEqual(tiledPixels, fullPixels)
        do {
            _ = try await renderer.prepareHalfInput(image, bounds: image.extent, colorSpace: space, budget: 4096)
            XCTFail("Output plus staging must be admitted before allocation")
        } catch is TileAllocationLimit { }
        let working = WorkingImageContract(referenceRenditionID: "test")
        let adapter = try InputAdapter(renderer: renderer, working: working)
        var descriptor = SourceDescriptor(id: "test", path: .processedPhoto); descriptor.recipeID = "ci"
        let recipe = InputRecipe(id: "ci", backend: "coreImage", version: "1", decodedRendition: .baseImage)
        let execution = ExecutionProfile(width: 512, height: 512, budget: .init(maxInFlightFrames: 1, maxResidentBytes: 3 * 1024 * 1024))
        let fallback = try await adapter.prepare(.image(image), descriptor: descriptor, recipe: recipe, execution: execution)
        XCTAssertEqual(fallback.width, 512); XCTAssertEqual(fallback.valueBounds.lower, 0.3, accuracy: 0.002)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await renderer.prepareHalfInput(image, bounds: image.extent, colorSpace: space, budget: 8 * 1024 * 1024)
        }
        do { _ = try await cancelled.value; XCTFail("Cancelled input must not be prepared") }
        catch is CancellationError { }
    }
}
