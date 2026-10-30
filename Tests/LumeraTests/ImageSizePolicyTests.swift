import XCTest
import ImagingCore
import ImageRendering
import Metal
@testable import ImageAnalysis

final class ImageSizePolicyTests:XCTestCase {
    func testDimensionsAndRequestedLimitAreNotBusinessCapped()throws {
        for (w,h) in [(8064,6048),(9504,6336),(20000,4000)] {
            try InputDescriptor(width:w,height:h).validate()
            try RenderRequest(input:.init(width:w,height:h),maximumLongEdge:12000).validate()
        }
    }
    func testInvalidAndOverflowDimensionsStillFail() {
        for (w,h) in [(0,1),(-1,1),(Int.max,2),(Int.max/8,1)] {
            XCTAssertThrowsError(try InputDescriptor(width:w,height:h).validate())
            XCTAssertThrowsError(try ImageFrame(width:w,height:h,pixels:[]))
        }
        XCTAssertThrowsError(try RenderRequest(input:.init(width:1,height:1),maximumLongEdge:0).validate())
    }
    func testDeviceLimitIsRejectedBeforeTextureAllocation()throws {
        let frame=try ImageFrame.solid(width:32769,height:1,value:0.5)
        try frame.descriptor.validate() // Legal host image; unsupported single GPU texture.
        let renderer=try MetalRenderer()
        XCTAssertThrowsError(try renderer.render(frame,style:ResolvedStyle(profile:.standard),request:RenderRequest(input:frame.descriptor))) { error in
            XCTAssertTrue(error.localizedDescription.contains("GPU"))
        }
    }
    func testWideImageRoundTripAndRenderingPreserveSize()throws {
        let frame=try ImageFrame.solid(width:9000,height:2,value:0.5)
        let file=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".png")
        defer{try? FileManager.default.removeItem(at:file)}
        try ImageCodec.encodeReference(frame).write(to:file)
        let loaded=try ImageCodec.load(file)
        XCTAssertEqual(loaded.width,9000);XCTAssertEqual(loaded.height,2)
        let renderer=try MetalRenderer()
        var p=Profile.standard;p.parameters.color.exposureEV=0.5
        let result=try renderer.render(loaded,style:ResolvedStyle(profile:p),request:RenderRequest(input:loaded.descriptor))
        XCTAssertEqual(result.image.width,9000);XCTAssertEqual(result.image.height,2)
        let scaled=try renderer.render(loaded,style:ResolvedStyle(profile:p),request:RenderRequest(input:loaded.descriptor,maximumLongEdge:8500))
        XCTAssertEqual(scaled.image.width,8500)
    }
}
