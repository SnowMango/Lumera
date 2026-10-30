@testable import ImageAnalysis
import XCTest
import Metal
import ImagingCore
@testable import ImageRendering
final class GPUNoiseMeasurementTests:XCTestCase {
    func testNoiseAndTextureMatchCPUAcrossOddCropsAndAmplitudes() throws {
        let device=try XCTUnwrap(MTLCreateSystemDefaultDevice()),gpu=try GPUNoiseMeasurement(device:device)
        for (w,h) in [(17,19),(65,71),(257,193)] {
            for amplitude in [0.0,0.00001,0.03] {
                let frame=try fixture(w,h,amplitude:amplitude),t=try texture(frame,device:device)
                for roi in [Region(),Region(x:0.03,y:0.02,width:0.96,height:0.96)] {
                    for kind in [MeasurementKind.noise,.texture] {
                        let expected=try MeasurementEngine.measure(frame,region:roi,kind:kind)
                        let actual=try gpu.measure(t,region:roi,kind:kind)
                        for key in ["mean","sigmaY","sigmaCb","sigmaCr","rms"] {
                            XCTAssertEqual(actual.metrics[key]!,expected.metrics[key]!,accuracy:2e-7,"\(key) \(w)x\(h) amplitude \(amplitude)")
                        }
                        XCTAssertEqual(actual.metrics["chromaCorrelation"]!,expected.metrics["chromaCorrelation"]!,accuracy:0.002)
                        let a=actual.curves["psd"]!,b=expected.curves["psd"]!
                        XCTAssertEqual(a.count,33)
                        for i in a.indices {XCTAssertEqual(a[i],b[i],accuracy:max(1e-13,abs(b[i])*0.0002),"PSD \(i)")}
                        XCTAssertEqual(actual.curves["frequency"],expected.curves["frequency"])
                        XCTAssertEqual(actual.warnings,expected.warnings)
                        XCTAssertEqual(actual.width,expected.pixelWidth);XCTAssertEqual(actual.height,expected.pixelHeight)
                        XCTAssertLessThan(actual.readbackBytes,1024);XCTAssertGreaterThan(actual.submissions,0)
                    }
                }
            }
        }
    }
    func testFlatAndSinusoidalTextureAnalyticBehavior() throws {
        let d=try XCTUnwrap(MTLCreateSystemDefaultDevice()),gpu=try GPUNoiseMeasurement(device:d)
        for value:Float in [0,0.5,1] {
            let image=try ImageFrame.solid(width:79,height:67,value:value)
            let s=try gpu.measure(texture(image,device:d),region:Region(),kind:.noise)
            XCTAssertEqual(s.metrics["sigmaY"]!,0,accuracy:1e-12)
            XCTAssertEqual(s.metrics["sigmaCb"]!,0,accuracy:1e-12)
            XCTAssertEqual(s.metrics["chromaCorrelation"]!,0,accuracy:1e-10)
            XCTAssertEqual(s.curves["psd"]!.max()!,0,accuracy:1e-24)
        }
        var pixels=[Float]()
        for _ in 0..<64 {for x in 0..<64 {let v=Float(0.5+0.1*cos(2*Double.pi*Double(x)*8/64));pixels += [v,v,v,1]}}
        let image=try ImageFrame(width:64,height:64,pixels:pixels)
        let s=try gpu.measure(texture(image,device:d),region:Region(),kind:.texture)
        XCTAssertEqual(s.metrics["sigmaY"]!,0.1/sqrt(2),accuracy:0.0001)
        XCTAssertEqual(s.curves["psd"]!.enumerated().max(by:{$0.element<$1.element})!.offset,8)
    }
    func testLargeOddImageReductionIsDeterministicAndRanksKnownAmplitude() throws {
        let d=try XCTUnwrap(MTLCreateSystemDefaultDevice()),gpu=try GPUNoiseMeasurement(device:d)
        let frame=try fixture(1025,769,amplitude:0.02),t=try texture(frame,device:d)
        let expected=try MeasurementEngine.measure(frame,kind:.noise)
        let actual=try gpu.measure(t,region:Region(),kind:.noise)
        let repeated=try gpu.measure(t,region:Region(),kind:.noise)
        XCTAssertEqual(actual.metrics,repeated.metrics);XCTAssertEqual(actual.curves,repeated.curves)
        for key in ["mean","sigmaY","sigmaCb","sigmaCr"] {XCTAssertEqual(actual.metrics[key]!,expected.metrics[key]!,accuracy:2e-7,key)}
        XCTAssertEqual(actual.metrics["chromaCorrelation"]!,expected.metrics["chromaCorrelation"]!,accuracy:0.002)
        XCTAssertEqual(actual.readbackBytes,156);XCTAssertGreaterThan(actual.gpuSeconds,0)
        var candidates=[(Double,Double)]()
        for amplitude in [0.01,0.015,0.02,0.025,0.03] {
            let sample=try gpu.measure(texture(fixture(1025,769,amplitude:amplitude),device:d),region:Region(),kind:.noise)
            let loss=["sigmaY","sigmaCb","sigmaCr"].reduce(0.0){$0+pow(sample.metrics[$1]!-expected.metrics[$1]!,2)}
            candidates.append((amplitude,loss))
        }
        XCTAssertEqual(candidates.min(by:{$0.1<$1.1})!.0,0.02)
    }
    func testInvalidScaleRegionAndCancellation() async throws {
        let d=try XCTUnwrap(MTLCreateSystemDefaultDevice()),gpu=try GPUNoiseMeasurement(device:d)
        let t=try texture(fixture(64,64,amplitude:0.03),device:d)
        for scale in [Double.nan,0,1.1] {XCTAssertThrowsError(try gpu.measure(t,region:Region(),kind:.noise,scale:scale))}
        XCTAssertThrowsError(try gpu.measure(t,region:Region(width:0.1),kind:.texture))
        XCTAssertThrowsError(try gpu.measure(t,region:Region(x:0.9),kind:.noise))
        let task=Task {withUnsafeCurrentTask{$0?.cancel()};return try gpu.measure(t,region:Region(),kind:.noise)}
        do {_=try await task.value;XCTFail("Cancelled work succeeded")}catch is CancellationError {}catch{XCTFail("\(error)")}
        XCTAssertNoThrow(try gpu.measure(t,region:Region(),kind:.noise))
    }
    private func fixture(_ w:Int,_ h:Int,amplitude:Double)throws->ImageFrame {
        var pixels=[Float](),state:UInt32=12345
        func random()->Double {state=1664525 &* state &+ 1013904223;return Double(state)/Double(UInt32.max)-0.5}
        for y in 0..<h {for x in 0..<w {
            let base=0.4+0.1*Double(x)/Double(w)+0.08*Double(y)/Double(h)
            let common=random()*amplitude
            pixels += [Float(base+common+random()*amplitude),Float(base+common),Float(base+common+random()*amplitude),1]
        }}
        return try ImageFrame(width:w,height:h,pixels:pixels)
    }
    private func texture(_ image:ImageFrame,device:MTLDevice)throws->MTLTexture {
        let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba32Float,width:image.width,height:image.height,mipmapped:false)
        d.storageMode = .shared;d.usage = [.shaderRead,.shaderWrite]
        let t=try XCTUnwrap(device.makeTexture(descriptor:d))
        image.pixels.withUnsafeBytes{t.replace(region:MTLRegionMake2D(0,0,image.width,image.height),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:image.width*16)}
        return t
    }
}
