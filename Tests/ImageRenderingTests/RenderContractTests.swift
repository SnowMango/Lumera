import XCTest
import Metal
import ImagingCore
@testable import ImageRendering

final class RenderContractTests:XCTestCase {
    func testInputContractRejectsMismatchAndUnsupportedTextures() throws {
        let h=try RenderHarness(),p=try h.encoder.prepare(ResolvedStyle(profile:.standard))
        let texture=try h.texture(width:32,height:32)
        var request=RenderRequest(input:InputDescriptor(width:31,height:32))
        XCTAssertThrowsError(try h.encode(texture,p,request))
        request.input.width=32;request.input.transfer = .pq
        XCTAssertThrowsError(try h.encode(texture,p,request))
        request.input.transfer = .sRGB;request.input.alphaMode = .premultiplied
        XCTAssertThrowsError(try h.encode(texture,p,request))
        request.input.alphaMode = .opaque
        let srgb=try h.texture(width:32,height:32,format:.rgba8Unorm_srgb)
        XCTAssertThrowsError(try h.encode(srgb,p,request))
        for other in MTLCopyAllDevices() where other.registryID != h.device.registryID {
            let otherQueue=try XCTUnwrap(other.makeCommandQueue()),cmd=try XCTUnwrap(otherQueue.makeCommandBuffer())
            XCTAssertThrowsError(try h.encoder.encode(texture,style:p,request:request,commandBuffer:cmd))
        }
    }
    func testStandardIsIdentityAndPreparedStyleIsSnapshot() throws {
        let h=try RenderHarness(),input=try h.texture(width:64,height:48)
        var profile=Profile.standard
        let style=try h.encoder.prepare(ResolvedStyle(profile:profile))
        profile.parameters.vignette.enabled=true;profile.parameters.vignette.amountEV=2
        let request=RenderRequest(input:InputDescriptor(width:64,height:48))
        let output=try h.encode(input,style,request)
        XCTAssertTrue(output === input)
        XCTAssertEqual(style.style.parameters,Profile.standard.parameters)
        XCTAssertEqual(h.encoder.cachedTextureBytes,0)
    }
    func testExposureBeforeLUTAndNeutralCurveDoesNotClipEarly() throws {
        let h=try RenderHarness();var p=Profile.standard;p.parameters.color.exposureEV=1
        // Linear cube implements encoded output * 0.5, making operation order observable.
        let cube="LUT_3D_SIZE 2\n0 0 0\n0.5 0 0\n0 0.5 0\n0.5 0.5 0\n0 0 0.5\n0.5 0 0.5\n0 0.5 0.5\n0.5 0.5 0.5\n"
        let lut=LUTAsset(name:"half",cubeText:cube)
        let result=try h.render(p,width:32,height:32,value:0.5,lut:lut)
        let expected=(1.055*pow(2*pow((0.5+0.055)/1.055,2.4),1/2.4)-0.055)*0.5
        XCTAssertEqual(Double(result[0]),expected,accuracy:0.001)
        p.parameters.tone.enabled=true
        p.parameters.vignette.enabled=true;p.parameters.vignette.amountEV=2;p.parameters.vignette.startRadius=0
        let out=try h.render(p,width:64,height:64,value:0.9)
        XCTAssertLessThan(out[0],0.9);XCTAssertGreaterThan(out[(32*64+32)*4],0.99)
    }
    func testPreviewGlowPolicyIsRequestOnly() throws {
        let h=try RenderHarness();var p=Profile.standard
        p.parameters.glow.enabled=true;p.parameters.glow.amount=0.6
        p.parameters.halation.enabled=true;p.parameters.halation.amount=0.5
        let original=p,source=try h.texture(width:128,height:128,point:true)
        let style=try h.encoder.prepare(ResolvedStyle(profile:p))
        var request=RenderRequest(input:InputDescriptor(width:128,height:128));request.previewGlow=false
        XCTAssertTrue(try h.encode(source,style,request) === source)
        request.previewGlow=true
        let output=RenderHarness.read(try h.encode(source,style,request))
        XCTAssertNotEqual(output,RenderHarness.read(source));XCTAssertEqual(p,original)
    }
    func testNoiseAndGrainSeedDeterminismAndCacheRelease() throws {
        let h=try RenderHarness();var p=Profile.standard
        p.parameters.noise.enabled=true;p.parameters.noise.curve = .init(knots:zip([0.0,0.18,0.5,0.85,1],Array(repeating:0.02,count:5)).map{.init(x:$0,y:$1)})
        p.parameters.grain.enabled=true;p.parameters.grain.amount=0.02
        let a=try h.render(p,width:96,height:64)
        XCTAssertEqual(a,try h.render(p,width:96,height:64))
        XCTAssertNotEqual(a,try h.render(p,width:96,height:64,seed:1729))
        XCTAssertNotEqual(a,try h.render(p,width:96,height:64,frame:1))
        for size in [127,80,193,96] {
            let actual=try h.render(p,width:size,height:64)
            XCTAssertEqual(actual,try RenderHarness().render(p,width:size,height:64))
        }
        XCTAssertGreaterThan(h.encoder.cachedTextureBytes,0)
        h.encoder.releaseCaches();XCTAssertEqual(h.encoder.cachedTextureBytes,0)
        XCTAssertEqual(a,try h.render(p,width:96,height:64))
    }
    func testReleaseCachesDoesNotRecycleInFlightOutput() throws {
        let h=try RenderHarness();var p=Profile.standard;p.parameters.color.exposureEV=1
        let input=try h.texture(width:32,height:32),style=try h.encoder.prepare(ResolvedStyle(profile:p))
        let cmd=try XCTUnwrap(h.queue.makeCommandBuffer())
        _=try h.encoder.encode(input,style:style,request:RenderRequest(input:InputDescriptor(width:32,height:32)),commandBuffer:cmd)
        h.encoder.releaseCaches()
        let done=DispatchSemaphore(value:0);cmd.addCompletedHandler{_ in done.signal()};cmd.commit();done.wait()
        XCTAssertNil(cmd.error);XCTAssertEqual(h.encoder.cachedTextureBytes,0)
    }
    func testSupportedMaximumRadiiAndExtremeColorRemainFinite() throws {
        let h=try RenderHarness();var p=Profile.standard
        p.parameters.glow.enabled=true;p.parameters.glow.amount=1;p.parameters.glow.farSigma=64
        let flat=try h.render(p,width:8192,height:8,value:0.6)
        XCTAssertEqual(flat[0],0.6,accuracy:0.003)
        p.parameters.color.whiteBalance.source=Chromaticity(x:0.44309360431205197,y:0.18605332803746455)
        p.parameters.color.exposureEV=3
        let extreme=try h.encoder.prepare(ResolvedStyle(profile:p))
        let texture=try h.encode(h.texture(width:32,height:32),extreme,RenderRequest(input:InputDescriptor(width:32,height:32)))
        XCTAssertEqual(texture.pixelFormat,.rgba32Float,"Extreme white points must not overflow half-float optical intermediates")
        let values=RenderHarness.read(texture)
        XCTAssertTrue(values.allSatisfy{$0.isFinite && (0...1).contains($0)})
    }
}

struct RenderHarness {
    let device:MTLDevice,queue:MTLCommandQueue,encoder:TextureEffectEncoder
    init(precision:RenderingPrecision = .float16) throws {
        device=try XCTUnwrap(MTLCreateSystemDefaultDevice());queue=try XCTUnwrap(device.makeCommandQueue())
        encoder=try TextureEffectEncoder(device:device,precision:precision)
    }
    func texture(width:Int,height:Int,value:Float=0.5,format:MTLPixelFormat = .rgba32Float,point:Bool=false) throws -> MTLTexture {
        let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:format,width:width,height:height,mipmapped:false)
        d.storageMode = .shared;d.usage=[.shaderRead,.shaderWrite]
        let t=try XCTUnwrap(device.makeTexture(descriptor:d))
        if format == .rgba32Float {
            var pixels=[Float](repeating:value,count:width*height*4)
            if point {pixels=Array(repeating:0,count:pixels.count);for y in height/2-2...height/2+2 {for x in width/2-2...width/2+2 {for c in 0..<3 {pixels[(y*width+x)*4+c]=1}}}}
            for i in stride(from:3,to:pixels.count,by:4) {pixels[i]=1}
            pixels.withUnsafeBytes{t.replace(region:MTLRegionMake2D(0,0,width,height),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:width*16)}
        }
        return t
    }
    func encode(_ input:MTLTexture,_ style:PreparedCameraStyle,_ request:RenderRequest) throws -> MTLTexture {
        let cmd=try XCTUnwrap(queue.makeCommandBuffer()),done=DispatchSemaphore(value:0)
        let output=try encoder.encode(input,style:style,request:request,commandBuffer:cmd)
        cmd.addCompletedHandler{_ in done.signal()};cmd.commit();done.wait();XCTAssertNil(cmd.error)
        return output
    }
    func render(_ p:Profile,width:Int,height:Int,value:Float=0.5,seed:UInt32=42,frame:UInt32=0,lut:LUTAsset?=nil) throws -> [Float] {
        var request=RenderRequest(input:InputDescriptor(width:width,height:height));request.seed=seed;request.frameIndex=frame
        return Self.read(try encode(texture(width:width,height:height,value:value),encoder.prepare(ResolvedStyle(profile:p),lut:lut),request))
    }
    static func read(_ texture:MTLTexture)->[Float] {
        let count=texture.width*texture.height*4
        if texture.pixelFormat == .rgba16Float {
            var values=[Float16](repeating:0,count:count)
            values.withUnsafeMutableBytes{texture.getBytes($0.baseAddress!,bytesPerRow:texture.width*8,from:MTLRegionMake2D(0,0,texture.width,texture.height),mipmapLevel:0)}
            return values.map(Float.init)
        }
        var values=[Float](repeating:0,count:count)
        values.withUnsafeMutableBytes{texture.getBytes($0.baseAddress!,bytesPerRow:texture.width*16,from:MTLRegionMake2D(0,0,texture.width,texture.height),mipmapLevel:0)}
        return values
    }
}
