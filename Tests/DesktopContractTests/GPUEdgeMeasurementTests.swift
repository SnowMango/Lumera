@testable import ImageAnalysis
import XCTest
import Metal
import ImagingCore
@testable import ImageRendering
final class GPUEdgeMeasurementTests:XCTestCase {
    // Catches transposition, edge polarity, ROI indexing and physical-scale binning errors.
    func testLogisticEdgeParityAcrossOrientationCropAndScale() throws {
        let device=try XCTUnwrap(MTLCreateSystemDefaultDevice()),gpu=try GPUEdgeMeasurement(device:device)
        for transpose in [false,true] {for reverse in [false,true] {
            let frame=try edge(width:157,height:133,transpose:transpose,reverse:reverse)
            let texture=try upload(frame,device)
            for roi in [Region(),Region(x:0.07,y:0.09,width:0.83,height:0.82)] {for scale in [0.7,1.0,1.6] {
                let expected=try MeasurementEngine.measure(frame,region:roi,kind:.edge,scale:scale)
                let actual=try gpu.measure(texture,region:roi,scale:scale)
                for key in ["mean","contrast","slope","mtf50","overshoot","undershoot"] {
                    XCTAssertEqual(try XCTUnwrap(actual.metrics[key]),try XCTUnwrap(expected.metrics[key]),accuracy:2e-5,"\(key), transpose=\(transpose), reverse=\(reverse), scale=\(scale)")
                }
                for key in ["edge","mtf"] {
                    let a=try XCTUnwrap(actual.curves[key]),b=try XCTUnwrap(expected.curves[key])
                    XCTAssertEqual(a.count,b.count)
                    XCTAssertLessThan(zip(a,b).map{abs($0-$1)}.max() ?? 1,3e-5,key)
                }
                XCTAssertEqual(actual.width,expected.pixelWidth);XCTAssertEqual(actual.height,expected.pixelHeight)
                XCTAssertEqual(actual.warnings,expected.warnings)
                XCTAssertLessThan(actual.readbackBytes,actual.width*actual.height*16)
                XCTAssertGreaterThan(actual.submissions,0);XCTAssertGreaterThan(actual.gpuSeconds,0)
            }}
        }}
    }
    // Catches loss of sharpening response and binning drift in actual renderer output.
    func testRenderedDetailParityAndKnownParameterRecovery() throws {
        let device=try XCTUnwrap(MTLCreateSystemDefaultDevice()),gpu=try GPUEdgeMeasurement(device:device)
        let renderer=try MetalRenderer(),input=try Fixtures.make(.edge,width:257,height:193)
        var profile=TestProfiles.ccd;profile.parameters.glow.enabled=false;profile.parameters.noise.enabled=false;profile.parameters.vignette.enabled=false
        // Renderer scales sigma by long edge / 2048; preserve an observable blur at 257 px.
        profile.parameters.detail.sharpenSigma=6.4;profile.parameters.detail.sharpenAmount=0.6
        let target=try MeasurementEngine.measure(renderer.renderStyle(input,profile:profile).image,kind:.edge)
        var scores=[(Double,Double)](),maxMetric=0.0,maxCurve=0.0
        for sharpen in [0.0,0.3,0.6,0.9,1.0] {
            profile.parameters.detail.sharpenAmount=sharpen
            let frame=try renderer.renderStyle(input,profile:profile).image
            let expected=try MeasurementEngine.measure(frame,kind:.edge)
            let actual=try gpu.measure(upload(frame,device),region:Region())
            for key in ["mean","contrast","slope","mtf50","overshoot","undershoot"] {
                let difference=abs(actual.metrics[key]!-expected.metrics[key]!)
                maxMetric=max(maxMetric,difference)
                XCTAssertLessThan(difference,2e-5,key)
            }
            for key in ["edge","mtf"] {
                let error=zip(actual.curves[key]!,expected.curves[key]!).map{abs($0-$1)}.max()!
                maxCurve=max(maxCurve,error);XCTAssertLessThan(error,3e-5,key)
            }
            let score=zip(actual.curves["mtf"]!,target.curves["mtf"]!).reduce(0.0){$0+pow($1.0-$1.1,2)}
            scores.append((sharpen,score))
        }
        XCTAssertEqual(scores.min{$0.1<$1.1}!.0,0.6)
        print("GPU edge rendered maximum metric error: \(maxMetric); maximum curve error: \(maxCurve)")
    }
    func testInvalidEdgesAndCancellationDoNotPoisonReuse() async throws {
        let device=try XCTUnwrap(MTLCreateSystemDefaultDevice()),gpu=try GPUEdgeMeasurement(device:device)
        let good=try upload(edge(width:96,height:96),device)
        XCTAssertThrowsError(try gpu.measure(upload(ImageFrame.solid(width:64,height:64,value:0.5),device),region:Region()))
        XCTAssertThrowsError(try gpu.measure(upload(edge(width:96,height:96,slope:0),device),region:Region()))
        XCTAssertThrowsError(try gpu.measure(good,region:Region(width:0.2)))
        XCTAssertThrowsError(try gpu.measure(good,region:Region(),scale:.nan))
        let task=Task {withUnsafeCurrentTask{$0?.cancel()};return try gpu.measure(good,region:Region())}
        do {_=try await task.value;XCTFail("Expected cancellation")} catch is CancellationError {} catch {XCTFail("\(error)")}
        XCTAssertNoThrow(try gpu.measure(good,region:Region()))
    }
    private func edge(width:Int,height:Int,transpose:Bool=false,reverse:Bool=false,slope:Double=0.137) throws -> ImageFrame {
        var pixels=[Float](repeating:1,count:width*height*4)
        for y in 0..<height {for x in 0..<width {
            let u=Double(transpose ? y:x),v=Double(transpose ? x:y)
            let w=Double(transpose ? height:width),h=Double(transpose ? width:height)
            let distance=(u-w*0.493-slope*(v-(h-1)/2))*(reverse ? -1:1)
            let value=0.14+0.69/(1+exp(-distance/1.7))
            let i=(y*width+x)*4
            pixels[i]=Float(value*0.95);pixels[i+1]=Float(value);pixels[i+2]=Float(value*1.04)
        }}
        return try ImageFrame(width:width,height:height,pixels:pixels)
    }
    private func upload(_ frame:ImageFrame,_ device:MTLDevice) throws -> MTLTexture {
        let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba32Float,width:frame.width,height:frame.height,mipmapped:false)
        descriptor.storageMode = .shared;descriptor.usage = [.shaderRead]
        let texture=try XCTUnwrap(device.makeTexture(descriptor:descriptor))
        frame.pixels.withUnsafeBytes{texture.replace(region:MTLRegionMake2D(0,0,frame.width,frame.height),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:frame.width*16)}
        return texture
    }
}
