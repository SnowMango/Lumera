import XCTest
import CoreImage
import Metal
import ImagingCore
@testable import ImageRendering

final class InputRangeReductionTests: XCTestCase {
    func testValidAreaExcludesStalePixelsAndBudgetIncludesEveryLevel() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice()), queue = try XCTUnwrap(device.makeCommandQueue())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: 513, height: 259, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.shaderRead]
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        var pixels = [SIMD4<Float>](repeating: .init(.nan, .infinity, 0, 1), count: 513 * 259)
        for y in 0..<19 { for x in 0..<17 { pixels[y * 513 + x] = .init(-2, 0.25, 3, 100) } }
        pixels.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, 513, 259), mipmapLevel: 0,
            withBytes: $0.baseAddress!, bytesPerRow: 513 * 16) }
        let reducer = try InputRangeReducer(device: device)
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let budget = TileWorkingSet(limit: reducer.estimatedBytes(width: 17, height: 19))
        let result = try reducer.encode(texture, commandBuffer: command, workingSet: budget, width: 17, height: 19)
        command.commit(); command.waitUntilCompleted()
        XCTAssertNil(command.error)
        XCTAssertEqual(try result.resolve(), .init(lower: -2, upper: 3), "Alpha is checked for finiteness, not included in RGB extrema")
        XCTAssertLessThanOrEqual(budget.bytes, budget.limit)
        let rejected = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertThrowsError(try reducer.encode(texture, commandBuffer: rejected, workingSet: TileWorkingSet(limit: 0)))
        XCTAssertEqual(rejected.status, .notEnqueued)
        XCTAssertThrowsError(try reducer.encode(texture, commandBuffer: rejected, width: 514))
        XCTAssertThrowsError(try reducer.encode(texture, commandBuffer: rejected, height: 0))
    }

    func testNonfiniteValuesInEveryChannelAreRejected() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice()), queue = try XCTUnwrap(device.makeCommandQueue())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: 1, height: 1, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.shaderRead]
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor)), reducer = try InputRangeReducer(device: device)
        for channel in 0..<4 { for invalid in [Float.nan, .infinity, -.infinity] {
            var value = SIMD4<Float>(0, 0.25, 1, 1); value[channel] = invalid
            withUnsafeBytes(of: value) { texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 16) }
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            let result = try reducer.encode(texture, commandBuffer: command)
            command.commit(); command.waitUntilCompleted()
            XCTAssertNil(command.error)
            XCTAssertThrowsError(try result.resolve(), "channel \(channel), value \(invalid)")
        } }
    }

    func testHierarchicalRangeIncludesOddEdgesAndAlphaFailures() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw XCTSkip("Metal unavailable") }
        let width = 513, height = 259
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.shaderRead]
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let reducer = try InputRangeReducer(device: device)
        var pixels = [SIMD4<Float>](repeating: .init(0.5, 0.5, 0.5, 1), count: width * height)
        pixels[width - 1].x = 12
        pixels[pixels.count - 1].y = -3
        for invalid in [false, true] {
            if invalid { pixels[pixels.count - 1].w = .nan }
            pixels.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                withBytes: $0.baseAddress!, bytesPerRow: width * 16) }
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            let result = try reducer.encode(texture, commandBuffer: command)
            XCTAssertEqual(result.count, 1, "CPU readback must stay bounded independently of image area")
            XCTAssertThrowsError(try result.resolve())
            command.commit(); command.waitUntilCompleted(); XCTAssertNil(command.error)
            if invalid { XCTAssertThrowsError(try result.resolve()) }
            else { XCTAssertEqual(try result.resolve(), .init(lower: -3, upper: 12)) }
        }
    }

    func testBoundedPreflightCoversPartialTilesAndRejectsHalfOverflow() async throws {
        let renderer = try LumeraRenderer(precision: .float16)
        let color = CGColorSpace(name: CGColorSpace.extendedSRGB)!
        let rect = CGRect(x: 0, y: 0, width: 2051, height: 1027)
        let base = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1, colorSpace: color)!).cropped(to: rect)
        let edge = CGRect(x: rect.maxX - 1, y: rect.maxY - 1, width: 1, height: 1)
        let bright = CIImage(color: CIColor(red: 4, green: 2, blue: 1, alpha: 1, colorSpace: color)!).cropped(to: edge).composited(over: base)
        let bounds = try await renderer.measureInputRange(bright, bounds: rect, colorSpace: color, budget: 2 * 1024 * 1024)
        XCTAssertEqual(bounds.lower, 0.5, accuracy: 0.001); XCTAssertEqual(bounds.upper, 4, accuracy: 0.001)
        let overflow = CIImage(color: CIColor(red: 100000, green: 1, blue: 1, alpha: 1, colorSpace: color)!).cropped(to: edge).composited(over: base)
        do {
            _ = try await renderer.measureInputRange(overflow, bounds: rect, colorSpace: color, budget: 2 * 1024 * 1024)
            XCTFail("Half preflight accepted overflow at the last pixel")
        } catch LabError.unsupported { }
    }

    func testSmallBudgetBatchesPreserveOffsetRegionAndSignedRange() async throws {
        let renderer = try LumeraRenderer(precision: .float16)
        let color = CGColorSpace(name: CGColorSpace.extendedSRGB)!
        let rect = CGRect(x: -7, y: 11, width: 131, height: 69)
        let base = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1, colorSpace: color)!).cropped(to: rect)
        let lastPixel = CGRect(x: rect.maxX - 1, y: rect.maxY - 1, width: 1, height: 1)
        let image = CIImage(color: CIColor(red: -2, green: 4, blue: 1, alpha: 1, colorSpace: color)!)
            .cropped(to: lastPixel).composited(over: base)
        let full = try await renderer.measureInputRange(image, bounds: rect, colorSpace: color, budget: 2 * 1024 * 1024)
        let small = try await renderer.measureInputRange(image, bounds: rect, colorSpace: color, budget: 32 * 1024)
        XCTAssertEqual(small.lower, full.lower, accuracy: 0.001)
        XCTAssertEqual(small.upper, full.upper, accuracy: 0.001)
        // Core Image color conversion can change the negative CIColor component.
        // Batching must preserve the full-render range and must not clamp it to zero.
        XCTAssertLessThan(small.lower, 0)
        XCTAssertEqual(small.upper, 4, accuracy: 0.001)
        do {
            _ = try await renderer.measureInputRange(image, bounds: rect, colorSpace: color, budget: 4095)
            XCTFail("Insufficient budget must reject")
        } catch LabError.invalid { }
    }

    func testCancelledLargeInputRejectsBeforeEnumeratingTiles() async throws {
        let renderer = try LumeraRenderer(precision: .float16)
        let rect = CGRect(x: 0, y: 0, width: 1_000_000, height: 1_000_000)
        let image = CIImage(color: .white).cropped(to: rect)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await renderer.measureInputRange(image, bounds: rect,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, budget: 4096)
        }
        do { _ = try await task.value; XCTFail("Cancelled work must not allocate or enumerate the huge input") }
        catch is CancellationError { }
    }
}
