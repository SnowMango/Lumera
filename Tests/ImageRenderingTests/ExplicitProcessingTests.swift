import XCTest
import CoreImage
import CoreVideo
import Metal
import ImagingCore
@testable import ImageRendering

final class ExplicitProcessingTests: XCTestCase {
    private func setup(parameters: StyleParameters = .init(), format: MTLPixelFormat = .rgba16Float,
                       slots: Int = 1) throws -> (LumeraRenderer, PreparedProcessingRequest, ProcessingResources) {
        let renderer = try LumeraRenderer()
        let style = try renderer.prepare(ResolvedStyle(parameters: parameters, profileDigest: "explicit-test"))
        let request = try PreparedProcessingRequest(renderer: renderer, style: style,
            input: .init(width: 33, height: 17), outputPixelFormat: format)
        let resources = ProcessingResources(device: renderer.device, policy: .init(maxInFlightFrames: slots))
        switch resources.prepare(request) {
        case .ready: break
        case .wouldBlock(let issue): throw issue
        case .failure(let error): throw error
        }
        return (renderer, request, resources)
    }
    private func acquire(_ resources: ProcessingResources, _ request: PreparedProcessingRequest) throws -> FrameResources {
        switch resources.acquireFrame(for: request) {
        case .ready(let frame): return frame
        case .unavailable(let issue): throw issue
        }
    }
    private func source(_ renderer: LumeraRenderer, value: Float16 = 0.25) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 33, height: 17, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]; d.storageMode = .shared
        let t = try XCTUnwrap(renderer.device.makeTexture(descriptor: d))
        var values = [Float16](repeating: value, count: 33 * 17 * 4)
        for i in stride(from: 3, to: values.count, by: 4) { values[i] = 1 }
        values.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0,0,33,17), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 33 * 8) }
        return t
    }
    private func red(_ image: CIImage, _ renderer: LumeraRenderer) -> Float {
        var data = [Float](repeating: 0, count: 4)
        data.withUnsafeMutableBytes { renderer.context.render(image, toBitmap: $0.baseAddress!, rowBytes: 16,
            bounds: .init(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: LumeraRenderer.sRGB) }
        return data[0]
    }
    func testExternalWorkspaceDoesNotCreateUnusedInputOrOutputStorage() throws {
        let renderer = try LumeraRenderer(), input = try source(renderer), output = try source(renderer)
        let style = try renderer.prepare(ResolvedStyle(parameters: .init()))
        let request = try PreparedProcessingRequest(renderer: renderer, style: style,
            input: .init(width: 33, height: 17), requiresImageStaging: false)
        let resources = ProcessingResources(device: renderer.device)
        let prepared = try resources.prepareWorkspace(input: input, output: output, request: request)
        XCTAssertEqual(resources.snapshot().allocationCount, 0)
        let done = expectation(description: "external output")
        let workspace = try prepared.acquire()
        XCTAssertThrowsError(try prepared.acquire())
        let result = renderer.processTexture(input, output: output, workspace: workspace, request: request) { result in
            do { XCTAssertTrue(try result.get() === output) } catch { XCTFail("\(error)") }
            done.fulfill()
        }
        guard case .accepted = result else { return XCTFail("Not accepted") }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(resources.snapshot().allocationCount, 0)
        prepared.close()
        XCTAssertThrowsError(try prepared.acquire())
    }
    func testEncodeDoesNotAllocatePixelStorageAndUsesProvidedOutput() throws {
        var parameters = StyleParameters(); parameters.color.exposureEV = 0.5
        let (renderer, request, resources) = try setup(parameters: parameters)
        let frame = try acquire(resources, request), input = try source(renderer)
        let count = resources.snapshot().allocationCount
        let done = expectation(description: "GPU complete")
        let submission = renderer.processTexture(input, output: frame.outputTexture, workspace: frame.workspace, request: request) { result in
            do { XCTAssertTrue(try result.get() === frame.outputTexture) } catch { XCTFail("\(error)") }
            done.fulfill()
        }
        guard case .accepted = submission else { return XCTFail("Not admitted") }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(count, resources.snapshot().allocationCount)
        let image = try frame.makeImageOutput(colorSpace: LumeraRenderer.sRGB).image
        XCTAssertGreaterThan(red(image, renderer), 0.25)
    }
    func testCIUsesCallerOutputAndHeldImageKeepsPixelsStable() throws {
        let (renderer, request, resources) = try setup(slots: 2)
        var images: [CIImage] = []
        for value in [0.2, 0.8] {
            try autoreleasepool {
                let frame = try acquire(resources, request)
                let output = try frame.makeImageOutput(colorSpace: LumeraRenderer.sRGB)
                let input = CIImage(color: CIColor(red: value, green: value, blue: value)).cropped(to: .init(x: 0, y: 0, width: 33, height: 17))
                let done = expectation(description: "CI complete")
                let result = renderer.processImage(input, output: output, context: renderer.context, workspace: frame.workspace, request: request) { result in
                    do { let image = try result.get(); XCTAssertTrue(image === output.image); images.append(image) }
                    catch { XCTFail("\(error)") }
                    done.fulfill()
                }
                guard case .accepted = result else { return XCTFail("Not admitted") }
                wait(for: [done], timeout: 10)
            }
        }
        XCTAssertEqual(red(images[0], renderer), 0.2, accuracy: 0.003)
        XCTAssertEqual(red(images[1], renderer), 0.8, accuracy: 0.003)
        XCTAssertGreaterThan(resources.snapshot().residentBytes, 0)
    }
    func testDuplicateWorkspaceDoesNotScheduleAnotherCallback() throws {
        let (renderer, request, resources) = try setup()
        let frame = try acquire(resources, request), input = try source(renderer)
        let done = expectation(description: "first")
        _ = renderer.processTexture(input, output: frame.outputTexture, workspace: frame.workspace, request: request) { _ in done.fulfill() }
        let duplicate = renderer.processTexture(input, output: frame.outputTexture, workspace: frame.workspace, request: request) { _ in XCTFail("Duplicate callback") }
        guard case .notAccepted = duplicate else { return XCTFail("Duplicate accepted") }
        wait(for: [done], timeout: 10)
    }
    func testUnsubmittedCommandRetainsWorkspaceAfterHandleAbandoned() throws {
        let (renderer, request, resources) = try setup()
        var command: MTLCommandBuffer? = renderer.queue.makeCommandBuffer()
        weak var observed: ProcessingWorkspace?
        try autoreleasepool {
            let frame = try acquire(resources, request), input = try source(renderer)
            observed = frame.workspace
            let encoded = try renderer.encode(input: input, output: frame.outputTexture, workspace: frame.workspace,
                request: request, commandBuffer: try XCTUnwrap(command))
            encoded.abandon()
        }
        XCTAssertNotNil(observed)
        command = nil
        XCTAssertNil(observed)
    }
    func testPixelBufferReturnsProvidedStorage() throws {
        let (renderer, request, resources) = try setup(format: .bgra8Unorm)
        let frame = try acquire(resources, request)
        func buffer() throws -> CVPixelBuffer {
            var result: CVPixelBuffer?
            let attrs: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]]
            XCTAssertEqual(CVPixelBufferCreate(nil, 33, 17, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &result), kCVReturnSuccess)
            return try XCTUnwrap(result)
        }
        let input = try buffer(), output = try buffer()
        CVPixelBufferLockBaseAddress(input, [])
        CVPixelBufferGetBaseAddress(input)!.initializeMemory(as: UInt8.self, repeating: 128, count: CVPixelBufferGetDataSize(input))
        CVPixelBufferUnlockBaseAddress(input, [])
        var cache: CVMetalTextureCache?
        XCTAssertEqual(CVMetalTextureCacheCreate(nil, nil, renderer.device, nil, &cache), kCVReturnSuccess)
        let done = expectation(description: "CV complete")
        let result = renderer.processBuffer(input, output: output, textureCache: try XCTUnwrap(cache), workspace: frame.workspace, request: request) { result in
            do { XCTAssertTrue(try result.get() === output) } catch { XCTFail("\(error)") }
            done.fulfill()
        }
        guard case .accepted = result else { return XCTFail("Not admitted") }
        wait(for: [done], timeout: 10)
        CVPixelBufferLockBaseAddress(output, .readOnly)
        XCTAssertEqual(CVPixelBufferGetBaseAddress(output)!.load(as: UInt8.self), 128)
        CVPixelBufferUnlockBaseAddress(output, .readOnly)
    }
}
