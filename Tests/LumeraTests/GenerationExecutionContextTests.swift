import XCTest
import Metal
import ImagingCore
import ImageRendering
@testable import ImageAnalysis

final class GenerationExecutionContextTests:XCTestCase {
    func testMeasurementServiceCanBeReplacedWithoutMetal() throws {
        struct Fake:PatchMeasuring {
            func predictColors(_ inputs:[[Double]],style:ResolvedStyle)throws->[[Double]] { inputs }
            func patches(frame:FrameMeasurements,style:ResolvedStyle,resources:RenderResources,regions:[TargetRegion])throws->[PatchMeasurement] { frame.patches }
        }
        let service:any PatchMeasuring=Fake()
        XCTAssertEqual(try service.predictColors([[0.1,0.2,0.3]],style:ResolvedStyle(profile:.standard)),[[0.1,0.2,0.3]])
    }
    func testExplicitDeviceAndRepeatedRelease() throws {
        let device=try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let context=try GenerationExecutionContext(device:device,cacheLimitBytes:1024*1024)
        XCTAssertEqual(context.renderer.device.registryID,device.registryID)
        context.releaseCaches();context.releaseCaches()
        XCTAssertThrowsError(try GenerationExecutionContext(device:device,cacheLimitBytes:-1))
    }
}
