import XCTest
import Metal
@testable import ImageAnalysis

final class GenerationExecutionContextTests:XCTestCase {
    func testExplicitDeviceAndRepeatedRelease() throws {
        let device=try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let context=try GenerationExecutionContext(device:device,cacheLimitBytes:1024*1024)
        XCTAssertEqual(context.renderer.device.registryID,device.registryID)
        context.releaseCaches();context.releaseCaches()
        XCTAssertThrowsError(try GenerationExecutionContext(device:device,cacheLimitBytes:-1))
    }
}
