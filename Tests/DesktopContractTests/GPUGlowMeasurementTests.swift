@testable import ImageAnalysis
import XCTest
import Metal
import ImagingCore
@testable import ImageRendering
final class GPUGlowMeasurementTests:XCTestCase {
    func testGlowGPUAgainstCPUMetricsWithCropAndScale() throws {
        let device=try XCTUnwrap(MTLCreateSystemDefaultDevice()),gpu=try GPUGlowMeasurement(device:device)
        let renderer=try MetalRenderer()
        var p=TestProfiles.ccd;p.parameters.detail.enabled=false;p.parameters.vignette.enabled=false;p.parameters.noise.enabled=false
        p.parameters.glow.amount=0.6
        for (w,h) in [(128,128),(257,193)] {
            let frame=try renderer.renderStyle(Fixtures.make(.point,width:w,height:h),profile:p).image
            let t=try texture(frame,device:device)
            for roi in [Region(),Region(x:0.15,y:0.15,width:0.7,height:0.7)] {
                let expected=try MeasurementEngine.measure(frame,region:roi,kind:.glow,scale:1.3)
                let actual=try gpu.measure(t,region:roi,scale:1.3)
                for key in ["mean","peak","background"] {XCTAssertEqual(actual.metrics[key]!,expected.metrics[key]!,accuracy:2e-6,key)}
                XCTAssertEqual(actual.metrics["spread"]!,expected.metrics["spread"]!,accuracy:0.002)
                XCTAssertEqual(actual.metrics["energy"]!,expected.metrics["energy"]!,accuracy:expected.metrics["energy"]!*2e-5)
                for key in ["radial","encircled","energy","crossSection"] {
                    let a=try XCTUnwrap(actual.curves[key]),b=try XCTUnwrap(expected.curves[key]);XCTAssertEqual(a.count,b.count)
                    XCTAssertLessThan(zip(a,b).map{abs($0-$1)}.max() ?? 1,0.002,key)
                }
                XCTAssertLessThan(actual.readbackBytes,w*h*16)
                XCTAssertGreaterThan(actual.submissions,0);XCTAssertGreaterThan(actual.gpuSeconds,0)
            }
        }
    }
    func testInvalidGlowRejectsAndCancelDoesNotPoisonReuse() async throws {
        let d=try XCTUnwrap(MTLCreateSystemDefaultDevice()),gpu=try GPUGlowMeasurement(device:d)
        let flat=try texture(ImageFrame.solid(width:64,height:64,value:0.5),device:d)
        XCTAssertThrowsError(try gpu.measure(flat,region:Region()))
        XCTAssertThrowsError(try gpu.measure(flat,region:Region(width:0.1)))
        let point=try texture(Fixtures.make(.point,width:96,height:96),device:d)
        let task=Task {withUnsafeCurrentTask{$0?.cancel()};return try gpu.measure(point,region:Region())}
        do {_=try await task.value;XCTFail("cancelled")}catch is CancellationError {}catch{XCTFail("\(error)")}
        XCTAssertNoThrow(try gpu.measure(point,region:Region()))
    }
    private func texture(_ image:ImageFrame,device:MTLDevice)throws->MTLTexture {
        let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba32Float,width:image.width,height:image.height,mipmapped:false)
        d.storageMode = .shared;d.usage = [.shaderRead,.shaderWrite]
        let t=try XCTUnwrap(device.makeTexture(descriptor:d))
        image.pixels.withUnsafeBytes{t.replace(region:MTLRegionMake2D(0,0,image.width,image.height),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:image.width*16)}
        return t
    }
}
