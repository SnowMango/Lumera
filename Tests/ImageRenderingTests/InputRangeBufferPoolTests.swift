import XCTest
import Metal
import ImagingCore
@testable import ImageRendering

final class InputRangeBufferPoolTests: XCTestCase {
    private func fixture() throws -> (MTLDevice, MTLCommandQueue, MTLTexture, InputRangeReducer, ProcessingResources) {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: 17, height: 19, mipmapped: false)
        d.storageMode = .shared; d.usage = [.shaderRead]
        let texture = try XCTUnwrap(device.makeTexture(descriptor: d))
        fill(texture, 0.5)
        let pool = ProcessingResources(device: device, limits: .init(maxResidentBytes: 1024 * 1024),
            policy: .init(maxResidentBytes: 1024 * 1024, maxIdleBytes: 1024 * 1024))
        return (device, queue, texture, try InputRangeReducer(device: device), pool)
    }
    private func fill(_ texture: MTLTexture, _ value: Float) {
        let values = [SIMD4<Float>](repeating: .init(value, value, value, 1), count: texture.width * texture.height)
        values.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0,
            withBytes: $0.baseAddress!, bytesPerRow: texture.width * 16) }
    }
    func testPoolRejectsAnotherDeviceIdentityBeforeEncoding() throws {
        let (device, _, _, _, pool) = try fixture()
        XCTAssertNoThrow(try pool.checkRangeDevice(device.registryID))
        XCTAssertThrowsError(try pool.checkRangeDevice(device.registryID ^ 1))
        XCTAssertEqual(pool.snapshot().allocationCount, 0)
    }

    func testResolvedTicketReleasesPhysicalStorageAfterIdleEviction() throws {
        let (_, queue, texture, reducer, pool) = try fixture()
        var saved: InputRangeReadback?
        weak var storage: AnyObject?
        try autoreleasepool {
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            let ticket = try reducer.encode(texture, commandBuffer: command, resources: pool)
            storage = ticket.buffer
            command.commit(); command.waitUntilCompleted()
            XCTAssertEqual(try ticket.resolve(), .init(lower: 0.5, upper: 0.5))
            saved = ticket
        }
        pool.clearAllIdleResources()
        XCTAssertEqual(pool.snapshot().residentBytes, 0)
        XCTAssertNil(storage, "Resolved tickets must cache values, not uncharged physical storage")
        XCTAssertEqual(try saved?.resolve(), .init(lower: 0.5, upper: 0.5))
    }

    func testPreparationReclaimsIdleRangeBuffers() throws {
        let renderer = try LumeraRenderer()
        let style = try renderer.prepare(ResolvedStyle(parameters: .init()))
        let request = try PreparedProcessingRequest(renderer: renderer, style: style, input: .init(width: 31, height: 23))
        let measuring = ProcessingResources(device: renderer.device, policy: .init(maxInFlightFrames: 1, maxPendingFrames: 0))
        guard case .ready = measuring.prepare(request) else { return XCTFail("Measure fitting request") }
        let required = measuring.snapshot().residentBytes
        measuring.close()
        let pool = ProcessingResources(device: renderer.device, limits: .init(maxResidentBytes: required),
            policy: .init(maxResidentBytes: required, maxIdleBytes: required, maxInFlightFrames: 1, maxPendingFrames: 0))
        let inputOwner = pool.makeStreamResources()
        try autoreleasepool { _ = try inputOwner.acquireRangeBuffer(length: 16, options: .storageModeShared) }
        guard case .ready = pool.prepare(request) else { return XCTFail("Reclaimable buffers must not block preparation") }
        XCTAssertLessThanOrEqual(pool.snapshot().residentBytes, required)
    }

    func testMultipleSizesAndTicketsInOneCommandReuseOnlyAfterResolution() throws {
        let (device, queue, small, reducer, pool) = try fixture()
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: 513, height: 259, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = .shaderRead
        let large = try XCTUnwrap(device.makeTexture(descriptor: descriptor)); fill(large, 3)
        var allocations = 0
        for round in 0..<3 {
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            let first = try reducer.encode(small, commandBuffer: command, resources: pool)
            let second = try reducer.encode(large, commandBuffer: command, resources: pool)
            XCTAssertFalse(first.buffer === second.buffer)
            XCTAssertThrowsError(try first.resolve())
            command.commit(); command.waitUntilCompleted()
            XCTAssertEqual(try first.resolve(), .init(lower: 0.5, upper: 0.5))
            XCTAssertEqual(try second.resolve(), .init(lower: 3, upper: 3))
            if round == 0 { allocations = pool.snapshot().allocationCount }
            else { XCTAssertEqual(pool.snapshot().allocationCount, allocations) }
        }
    }

    func testBudgetAndStorageModesRemainIndependent() throws {
        let (device, _, _, _, pool) = try fixture()
        var first: ProcessingBufferLease? = try pool.acquireRangeBuffer(length: 16, options: .storageModeShared)
        let bytes = pool.snapshot().residentBytes
        _ = pool.updatePolicy(.init(maxResidentBytes: bytes, maxIdleBytes: bytes))
        XCTAssertThrowsError(try pool.acquireRangeBuffer(length: 16, options: .storageModeShared))
        withExtendedLifetime(first) {}
        first = nil
        let other = try pool.acquireRangeBuffer(length: 16, options: .storageModePrivate)
        XCTAssertEqual(other.buffer.storageMode, .private)
        XCTAssertEqual(other.buffer.device.registryID, device.registryID)
        XCTAssertLessThanOrEqual(pool.snapshot().residentBytes, bytes)
        pool.clearAllIdleResources()
        XCTAssertGreaterThan(pool.snapshot().residentBytes, 0, "Leased storage remains charged across generations")
    }

    func testWarmReductionReusesBuffers() throws {
        let (_, queue, texture, reducer, pool) = try fixture()
        var allocations = 0
        for i in 0..<4 {
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            let ticket = try reducer.encode(texture, commandBuffer: command, resources: pool)
            command.commit(); command.waitUntilCompleted()
            XCTAssertEqual(try ticket.resolve(), .init(lower: 0.5, upper: 0.5))
            if i == 0 { allocations = pool.snapshot().allocationCount }
            else { XCTAssertEqual(pool.snapshot().allocationCount, allocations) }
        }
        XCTAssertGreaterThan(allocations, 0)
        pool.clearAllIdleResources()
        XCTAssertEqual(pool.snapshot().residentBytes, 0)
    }
    func testCPUReadbackPinsResultBufferAndRepeatedResolveUsesSavedValue() throws {
        let (_, queue, texture, reducer, pool) = try fixture()
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let first = try reducer.encode(texture, commandBuffer: command, resources: pool)
        command.commit(); command.waitUntilCompleted()
        let count = pool.snapshot().allocationCount
        fill(texture, 2)
        let secondCommand = try XCTUnwrap(queue.makeCommandBuffer())
        let second = try reducer.encode(texture, commandBuffer: secondCommand, resources: pool)
        XCTAssertFalse(first.buffer === second.buffer)
        XCTAssertGreaterThan(pool.snapshot().allocationCount, count)
        secondCommand.commit(); secondCommand.waitUntilCompleted()
        XCTAssertEqual(try first.resolve(), .init(lower: 0.5, upper: 0.5))
        XCTAssertEqual(try second.resolve(), .init(lower: 2, upper: 2))
        fill(texture, 3)
        let thirdCommand = try XCTUnwrap(queue.makeCommandBuffer())
        let third = try reducer.encode(texture, commandBuffer: thirdCommand, resources: pool)
        thirdCommand.commit(); thirdCommand.waitUntilCompleted()
        XCTAssertEqual(try third.resolve(), .init(lower: 3, upper: 3))
        XCTAssertEqual(try first.resolve(), .init(lower: 0.5, upper: 0.5))
        XCTAssertEqual(try second.resolve(), .init(lower: 2, upper: 2))
    }
    func testCloseAndUnsubmittedCommandReleaseBufferCharges() throws {
        let (_, queue, texture, reducer, pool) = try fixture()
        try autoreleasepool {
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            let ticket = try reducer.encode(texture, commandBuffer: command, resources: pool)
            XCTAssertThrowsError(try ticket.resolve())
            pool.close()
            XCTAssertGreaterThan(pool.snapshot().residentBytes, 0)
        }
        XCTAssertEqual(pool.snapshot().residentBytes, 0)
        XCTAssertThrowsError(try pool.acquireRangeBuffer(length: 16, options: .storageModeShared))
    }
    func testFailedReadbackAndPolicyShrinkReturnStorage() throws {
        let (_, queue, texture, reducer, pool) = try fixture()
        fill(texture, .nan)
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let ticket = try reducer.encode(texture, commandBuffer: command, resources: pool)
        command.commit(); command.waitUntilCompleted()
        XCTAssertThrowsError(try ticket.resolve())
        XCTAssertThrowsError(try ticket.resolve())
        _ = pool.updatePolicy(.init(maxResidentBytes: 1024 * 1024, maxIdleBytes: 0))
        XCTAssertEqual(pool.snapshot().residentBytes, 0)
    }
}
