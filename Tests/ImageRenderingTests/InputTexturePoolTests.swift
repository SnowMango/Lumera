import XCTest
import Metal
@testable import ImageRendering

final class InputTexturePoolTests: XCTestCase {
    func testDifferentFormatReclaimsIdleStorageBeforeReportingBudgetExhaustion() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let resources = ProcessingResources(device: device, limits: .init(maxResidentBytes: 1024 * 1024),
            policy: .init(maxResidentBytes: 1024 * 1024, maxIdleBytes: 1024 * 1024))
        try autoreleasepool {
            _ = try resources.acquireInputTexture(width: 256, height: 256, format: .rgba16Float)
        }
        try autoreleasepool {
            let texture = try resources.acquireInputTexture(width: 256, height: 256, format: .rgba32Float)
            XCTAssertEqual(texture.pixelFormat, .rgba32Float)
            XCTAssertLessThanOrEqual(resources.snapshot().residentBytes, 1024 * 1024)
        }
    }

    func testAcquiresOnlyRequestedTextureAndReusesReleasedStorage() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let resources = ProcessingResources(device: device)
        var identity: ObjectIdentifier?
        try autoreleasepool {
            let texture = try resources.acquireInputTexture(width: 16, height: 16, format: .rgba32Float)
            identity = ObjectIdentifier(try XCTUnwrap(texture.parent))
            XCTAssertEqual(resources.snapshot().allocationCount, 1)
        }
        try autoreleasepool {
            let staging = try resources.acquireInputTexture(width: 16, height: 16, format: .rgba32Float)
            XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(staging.parent)), identity)
            XCTAssertEqual(resources.snapshot().allocationCount, 1)
            let output = try resources.acquireInputTexture(width: 16, height: 16, format: .rgba16Float)
            XCTAssertEqual(output.pixelFormat, .rgba16Float)
            XCTAssertEqual(resources.snapshot().allocationCount, 2)
        }
        resources.clearIdleResources()
        XCTAssertEqual(resources.snapshot().residentBytes, 0)
    }

    func testRetainedViewCannotBeReissuedAndCloseReleasesOnlyIdleStorage() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let resources = ProcessingResources(device: device)
        try autoreleasepool {
            let first = try resources.acquireInputTexture(width: 16, height: 16, format: .rgba16Float)
            let second = try resources.acquireInputTexture(width: 16, height: 16, format: .rgba16Float)
            XCTAssertFalse(first.parent === second.parent)
            resources.close()
            XCTAssertGreaterThan(resources.snapshot().residentBytes, 0)
            XCTAssertThrowsError(try resources.acquireInputTexture(width: 16, height: 16, format: .rgba16Float))
            withExtendedLifetime((first, second)) {}
        }
        XCTAssertEqual(resources.snapshot().residentBytes, 0)
    }
}
