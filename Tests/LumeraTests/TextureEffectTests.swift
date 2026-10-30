@testable import ImageAnalysis
import XCTest
import Metal
import ImagingCore
@testable import ImageRendering

final class TextureEffectTests:XCTestCase {
    func testTemporalPolicyDesktopAndDynamicRuntimeAgreeSeparately() throws {
        let device=try XCTUnwrap(MTLCreateSystemDefaultDevice()),queue=try XCTUnwrap(device.makeCommandQueue())
        let encoder=try TextureEffectEncoder(device:device),renderer=try MetalRenderer()
        let frame=try ImageFrame.solid(width:128,height:96,value:0.5),source=try upload(frame,device:device)
        for grain in [false,true] {for mode in TemporalMode.allCases {
            var p=Profile.standard;p.temporalPolicy.noise=mode;p.temporalPolicy.grain=mode
            if grain {p.parameters.grain.enabled=true;p.parameters.grain.amount=0.03}
            else {p.parameters.noise.enabled=true;p.parameters.noise.curve = .init(knots:zip([0.0,0.18,0.5,0.85,1],Array(repeating:0.03,count:5)).map{.init(x:$0,y:$1)})}
            let definition=try StyleEvaluator.compile(p),prepared=try encoder.prepare(definition),values=try StyleEvaluator.evaluate(definition)
            var outputs=[[Float]]()
            for index:UInt32 in [0,7,0] {
                var request=RenderRequest(input:frame.descriptor);request.frameIndex=index
                let expected=try renderer.render(frame,style:values.resolvedStyle(),request:request).image.pixels
                let command=try XCTUnwrap(queue.makeCommandBuffer()),done=DispatchSemaphore(value:0)
                let result=try encoder.encode(source,style:prepared,parameters:FrameStyleParameters(values),request:request,commandBuffer:command)
                command.addCompletedHandler{_ in done.signal()};command.commit();done.wait();XCTAssertNil(command.error)
                XCTAssertLessThan(zip(read(result),expected).map{abs($0-$1)}.max() ?? 1,0.006)
                outputs.append(expected)
            }
            XCTAssertEqual(outputs[0],outputs[2])
            if mode == .fixed {XCTAssertEqual(outputs[0],outputs[1])}else{XCTAssertNotEqual(outputs[0],outputs[1])}
        }}
    }
    func testTextureEncodingMatchesReferenceForAllEffectsAndLUT() throws {
        let device=try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue=try XCTUnwrap(device.makeCommandQueue())
        let encoder=try TextureEffectEncoder(device:device)
        var profile=try StylePresets.make("digital-demo")
        profile.parameters.vignette.centerX=0.3;profile.parameters.vignette.centerY=0.7
        profile.parameters.glow.threshold=0.3;profile.parameters.glow.amount=0.4
        let cube="LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 0.8 0\n1 0.8 0\n0 0 0.9\n1 0 0.9\n0 0.8 0.9\n1 0.8 0.9\n"
        let lut=LUTAsset(name:"channel scale",cubeText:cube)
        for fixture in [Fixture.patches,.point,.texture] {
            let frame=try Fixtures.make(fixture,width:96,height:64)
            let expected=try MetalRenderer().render(frame,style:ResolvedStyle(profile:profile),resources:.init(lut:lut),request:RenderRequest(input:frame.descriptor)).image
            let source=try upload(frame,device:device)
            let prepared=try encoder.prepare(ResolvedStyle(profile:profile),lut:lut)
            let command=try XCTUnwrap(queue.makeCommandBuffer())
            let result=try encoder.encode(source,style:prepared,request:RenderRequest(input:frame.descriptor),commandBuffer:command)
            command.commit();command.waitUntilCompleted()
            XCTAssertNil(command.error)
            let pixels=read(result)
            XCTAssertEqual(pixels.count,expected.pixels.count)
            let maximum=zip(pixels,expected.pixels).map{abs($0-$1)}.max() ?? 1
            XCTAssertLessThan(maximum,0.004,"\(fixture) mismatch")
        }
    }
    func testWideSupportedImageWithMaximumGlowRadius() throws {
        let device=try XCTUnwrap(MTLCreateSystemDefaultDevice()),queue=try XCTUnwrap(device.makeCommandQueue())
        let encoder=try TextureEffectEncoder(device:device)
        let frame=try ImageFrame.solid(width:8192,height:8,value:0.6)
        var profile=Profile.standard;profile.parameters.glow.enabled=true;profile.parameters.detail.enabled=false;profile.parameters.vignette.enabled=false;profile.parameters.noise.enabled=false
        profile.parameters.glow.farSigma=64;profile.parameters.glow.nearSigma=32;profile.parameters.glow.amount=1;profile.parameters.glow.threshold=0.1
        let command=try XCTUnwrap(queue.makeCommandBuffer()),done=DispatchSemaphore(value:0)
        let output=try encoder.encode(upload(frame,device:device),style:encoder.prepare(ResolvedStyle(profile:profile)),request:RenderRequest(input:frame.descriptor),commandBuffer:command)
        command.addCompletedHandler{_ in done.signal()};command.commit();done.wait()
        XCTAssertNil(command.error)
        let pixels=read(output)
        for i in stride(from:0,to:pixels.count,by:4) {XCTAssertEqual(pixels[i],0.6,accuracy:0.002)}
    }
    func testRepeatedFramesAndStyleChangesMatchFreshEncoding() throws {
        let device=try XCTUnwrap(MTLCreateSystemDefaultDevice()),queue=try XCTUnwrap(device.makeCommandQueue())
        let reused=try TextureEffectEncoder(device:device)
        func render(_ encoder:TextureEffectEncoder,_ frame:ImageFrame,_ profile:Profile) throws -> [Float] {
            let source=try upload(frame,device:device),style=try encoder.prepare(ResolvedStyle(profile:profile))
            let command=try XCTUnwrap(queue.makeCommandBuffer()),done=DispatchSemaphore(value:0)
            let texture=try encoder.encode(source,style:style,request:RenderRequest(input:frame.descriptor),commandBuffer:command)
            command.addCompletedHandler{_ in done.signal()};command.commit();done.wait()
            XCTAssertNil(command.error)
            return read(texture)
        }
        var changed=try StylePresets.make("digital-demo");changed.parameters.noise.lumaSigma=0;changed.parameters.noise.chromaSigma=0
        var disabled=try StylePresets.make("digital-demo");disabled.parameters.noise.enabled=false
        var recolored=try StylePresets.make("digital-demo");recolored.parameters.noise.curve = .init(knots:zip([0.0,0.18,0.5,0.85,1],[0.01,0.02,0.01,0.005,0]).map{.init(x:$0,y:$1)});recolored.parameters.noise.chromaRatio=0.6
        for (index,profile) in [try StylePresets.make("digital-demo"),try StylePresets.make("digital-demo"),changed,try StylePresets.make("digital-demo"),disabled,recolored,try StylePresets.make("digital-demo")].enumerated() {
            // The image changes even when the seed/profile is unchanged; only the noise field is reusable.
            let frame=try Fixtures.make(index%2 == 0 ? .patches:.texture,width:index == 5 ? 321:257,height:193)
            let actual=try render(reused,frame,profile)
            let expected=try render(TextureEffectEncoder(device:device),frame,profile)
            XCTAssertEqual(actual,expected,"Stale texture or noise cache at frame \(index)")
        }
    }
    func testStandardReturnsOriginalTextureAndPreparedStyleIsSnapshot() throws {
        let device=try XCTUnwrap(MTLCreateSystemDefaultDevice()),queue=try XCTUnwrap(device.makeCommandQueue())
        let encoder=try TextureEffectEncoder(device:device)
        let frame=try Fixtures.make(.patches,width:64,height:64),source=try upload(frame,device:device)
        var profile=Profile.standard
        let prepared=try encoder.prepare(ResolvedStyle(profile:profile))
        profile.parameters.vignette.amountEV=1.8
        let command=try XCTUnwrap(queue.makeCommandBuffer())
        let result=try encoder.encode(source,style:prepared,request:RenderRequest(input:frame.descriptor),commandBuffer:command)
        XCTAssertTrue(result === source)
        XCTAssertEqual(prepared.style.parameters,Profile.standard.parameters)
    }
    func testInvalidLUTDoesNotCreatePreparedStyle() throws {
        let device=try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let encoder=try TextureEffectEncoder(device:device)
        var profile=try StylePresets.make("digital-demo")
        let lut=LUTAsset(name:"broken",cubeText:"LUT_3D_SIZE 2\n0 0 0\n")
        XCTAssertThrowsError(try encoder.prepare(ResolvedStyle(profile:profile),lut:lut))
    }
    private func upload(_ frame:ImageFrame,device:MTLDevice) throws -> MTLTexture {
        let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba32Float,width:frame.width,height:frame.height,mipmapped:false)
        descriptor.storageMode = .shared;descriptor.usage = [.shaderRead,.shaderWrite]
        let texture=try XCTUnwrap(device.makeTexture(descriptor:descriptor))
        frame.pixels.withUnsafeBytes{texture.replace(region:MTLRegionMake2D(0,0,frame.width,frame.height),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:frame.width*16)}
        return texture
    }
    private func read(_ texture:MTLTexture)->[Float] {
        if texture.pixelFormat == .rgba16Float {
            var values=[Float16](repeating:0,count:texture.width*texture.height*4)
            values.withUnsafeMutableBytes{texture.getBytes($0.baseAddress!,bytesPerRow:texture.width*8,from:MTLRegionMake2D(0,0,texture.width,texture.height),mipmapLevel:0)}
            return values.map(Float.init)
        }
        var values=[Float](repeating:0,count:texture.width*texture.height*4)
        values.withUnsafeMutableBytes{texture.getBytes($0.baseAddress!,bytesPerRow:texture.width*16,from:MTLRegionMake2D(0,0,texture.width,texture.height),mipmapLevel:0)}
        return values
    }
}
