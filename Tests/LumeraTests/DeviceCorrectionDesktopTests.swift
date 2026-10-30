import XCTest
import Metal
import ImagingCore
import ImageRendering
@testable import ImageAnalysis

final class DeviceCorrectionDesktopTests:XCTestCase {
    func testSwitchingCorrectionsNeverReusesStalePixels() throws {
        let renderer=try MetalRenderer(),frame=try Fixtures.make(.patches,width:64,height:48)
        let style=try ResolvedStyle(profile:.standard),request=RenderRequest(input:frame.descriptor)
        var a=DeviceCorrection();a.matrix.values=[0,0,1,0,1,0,1,0,0]
        var b=DeviceCorrection();b.matrix.values=[0.8,0,0,0,0.9,0,0,0,1]
        for c in [nil,a,a,b,nil,DeviceCorrection()] {
            let actual=try renderer.render(frame,style:style,correction:c,request:request).image
            let fresh=try MetalRenderer().render(frame,style:style,correction:c,request:request).image
            XCTAssertEqual(actual.pixels,fresh.pixels)
            if c==nil || c==DeviceCorrection() {XCTAssertEqual(renderer.lastWork.correctionDispatches,0);XCTAssertEqual(actual.pixels,frame.pixels)}
        }
        renderer.releaseCaches();XCTAssertEqual(renderer.memoryStatistics["cachedTextureBytes"],"0")
    }
    func testSameNamedLUTContentAndCachedCorrectionAreIndependent() throws {
        let renderer=try MetalRenderer(),frame=try ImageFrame.solid(width:32,height:24,value:0.5)
        var c=DeviceCorrection()
        let style=try ResolvedStyle(profile:.standard),request=RenderRequest(input:frame.descriptor)
        for factor in [0.5,0.8,0.5] {
            var lines=["LUT_3D_SIZE 2"]
            for b in 0...1 {for g in 0...1 {for r in 0...1 {lines.append([r,g,b].map{String(Double($0)*factor)}.joined(separator:" "))}}}
            let lut=LUTAsset(name:"same",cubeText:lines.joined(separator:"\n"))
            let result=try renderer.render(frame,style:style,correction:c,resources:.init(correctionLUT:lut),request:request)
            XCTAssertEqual(result.image.pixels[0],Float(0.5*factor),accuracy:1e-5)
            XCTAssertEqual(renderer.lastWork.correctionDispatches,1)
            _=try renderer.render(frame,style:style,correction:c,resources:.init(correctionLUT:lut),request:request)
            XCTAssertEqual(renderer.lastWork.correctionDispatches,0)
            XCTAssertEqual(renderer.lastWork.uploads,0)
        }
    }
    func testFloat16RuntimeMatchesFloat32Desktop() throws {
        let device=try XCTUnwrap(MTLCreateSystemDefaultDevice()),queue=try XCTUnwrap(device.makeCommandQueue()),runtime=try TextureEffectEncoder(device:device)
        let frame=try Fixtures.make(.texture,width:128,height:96)
        var c=DeviceCorrection();c.whiteBalance.destination=Chromaticity(x:0.3457,y:0.3585);c.matrix.values=[0.9,0.05,0.02,0.03,0.95,0.01,0.02,0.04,0.9]
        let style=try ResolvedStyle(profile:StylePresets.make("film-demo"))
        let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba32Float,width:frame.width,height:frame.height,mipmapped:false);descriptor.storageMode = .shared;descriptor.usage=[.shaderRead,.shaderWrite]
        let input=try XCTUnwrap(device.makeTexture(descriptor:descriptor))
        frame.pixels.withUnsafeBytes{input.replace(region:MTLRegionMake2D(0,0,frame.width,frame.height),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:frame.width*16)}
        let cmd=try XCTUnwrap(queue.makeCommandBuffer()),done=DispatchSemaphore(value:0),request=RenderRequest(input:frame.descriptor)
        let out=try runtime.encode(input,style:runtime.prepare(style),correction:runtime.prepareCorrection(c),request:request,commandBuffer:cmd)
        cmd.addCompletedHandler{_ in done.signal()};cmd.commit();done.wait();XCTAssertNil(cmd.error)
        var values=[Float16](repeating:0,count:frame.pixels.count)
        values.withUnsafeMutableBytes{out.getBytes($0.baseAddress!,bytesPerRow:frame.width*8,from:MTLRegionMake2D(0,0,frame.width,frame.height),mipmapLevel:0)}
        let expected=try MetalRenderer().render(frame,style:style,correction:c,request:request).image
        let maximum=zip(values,expected.pixels).map{abs(Float($0)-$1)}.max()!
        print("Device correction runtime/desktop max channel delta: \(maximum)")
        XCTAssertLessThan(maximum,0.006)
    }
}
