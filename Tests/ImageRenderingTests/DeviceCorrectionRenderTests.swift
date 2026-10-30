import XCTest
import Metal
import ImagingCore
@testable import ImageRendering

final class DeviceCorrectionRenderTests:XCTestCase {
    func testAbsentAndExactIdentityAllocateNothing() throws {
        let h=try RenderHarness()
        XCTAssertNil(try h.encoder.prepareCorrection(nil))
        XCTAssertNil(try h.encoder.prepareCorrection(DeviceCorrection()))
        let c=DeviceCorrection(),lut=cube(square:false)
        XCTAssertNil(try h.encoder.prepareCorrection(c,lut:lut))
        let source=try h.texture(width:8,height:8)
        let out=try run(h,source:source,correction:c,lut:lut)
        XCTAssertTrue(out === source);XCTAssertEqual(h.encoder.cachedTextureBytes,0)
        let bad=LUTAsset(name:"bad",cubeText:"LUT_3D_SIZE 2\n0 0 0")
        XCTAssertThrowsError(try h.encoder.prepareCorrection(c,lut:bad))
    }
    func testCorrectionBeforeNonCommutingStyleAndLUT() throws {
        let h=try RenderHarness(),source=try h.texture(width:8,height:8)
        let pixels=Array(repeating:[Float](arrayLiteral:0.2,0.4,0.8,1),count:64).flatMap{$0}
        pixels.withUnsafeBytes{source.replace(region:MTLRegionMake2D(0,0,8,8),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:128)}
        var c=DeviceCorrection();c.matrix.values=[0,0,1,0,1,0,1,0,0]
        var p=Profile.standard;p.parameters.color.matrix.values=[0,1,0,0,0,1,1,0,0]
        let out=RenderHarness.read(try run(h,source:source,correction:c,profile:p))
        for (a,b) in zip(out.prefix(3),[Float](arrayLiteral:0.4,0.2,0.8)){XCTAssertEqual(a,b,accuracy:0.002)}
        let lut=cube(square:true);p.parameters.color.exposureEV=1
        let actual=RenderHarness.read(try run(h,source:source,correction:c,profile:p,lut:lut))
        func squareLUT(_ v:Double)->Double {v<=0.5 ? v*0.5:0.25+(v-0.5)*1.5}
        func exposure(_ v:Double)->Double {let lin=v<=0.04045 ? v/12.92:pow((v+0.055)/1.055,2.4);return 1.055*pow(lin*2,1/2.4)-0.055}
        for (a,b) in zip(actual.prefix(3),[0.4,0.2,0.8].map{exposure(squareLUT($0))}) {XCTAssertEqual(Double(a),b,accuracy:0.002)}
    }
    func testNonlinearCorrectionRunsBeforePreviewResize() throws {
        let h=try RenderHarness(),source=try h.texture(width:2,height:2)
        let pixels:[Float]=[0,0,0,1,1,1,1,1,0,0,0,1,1,1,1,1]
        pixels.withUnsafeBytes{source.replace(region:MTLRegionMake2D(0,0,2,2),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:32)}
        let c=DeviceCorrection(),lut=cube(square:true)
        let out=RenderHarness.read(try run(h,source:source,correction:c,limit:1,lut:lut))
        XCTAssertEqual(out[0],0.73535698,accuracy:0.002)
    }
    func testIdentityLUTStillClampsAfterNonIdentityMatrix() throws {
        let h=try RenderHarness(),source=try h.texture(width:8,height:8,value:0.9)
        var c=DeviceCorrection();c.matrix.values=[4,0,0,0,4,0,0,0,4];let lut=cube(square:false)
        var p=Profile.standard;p.parameters.color.exposureEV = -2
        let out=RenderHarness.read(try run(h,source:source,correction:c,profile:p,lut:lut))
        XCTAssertEqual(out[0],0.5370987,accuracy:0.002)
    }
    func testExtremeCorrectionPromotesPrecisionAndReleaseDuringFlight() throws {
        let h=try RenderHarness(),source=try h.texture(width:32,height:32)
        var c=DeviceCorrection();c.whiteBalance.source=Chromaticity(x:0.44309360431205197,y:0.18605332803746455)
        let correction=try h.encoder.prepareCorrection(c),cmd=try XCTUnwrap(h.queue.makeCommandBuffer())
        let out=try h.encoder.encode(source,style:h.encoder.prepare(ResolvedStyle(profile:.standard)),correction:correction,request:RenderRequest(input:InputDescriptor(width:32,height:32)),commandBuffer:cmd)
        XCTAssertEqual(out.pixelFormat,.rgba32Float)
        h.encoder.releaseCaches()
        let done=DispatchSemaphore(value:0);cmd.addCompletedHandler{_ in done.signal()};cmd.commit();done.wait()
        XCTAssertNil(cmd.error);XCTAssertEqual(h.encoder.cachedTextureBytes,0)
        XCTAssertTrue(RenderHarness.read(out).allSatisfy{$0.isFinite && (0...1).contains($0)})
        XCTAssertThrowsError(try h.encoder.encode(source,style:h.encoder.prepare(ResolvedStyle(profile:.standard)),correction:correction,request:RenderRequest(input:InputDescriptor(width:32,height:32)),commandBuffer:cmd))
    }
    func testFloat32D65ToD50AgainstIndependentWhiteVector() throws {
        let h=try RenderHarness(),encoder=try TextureEffectEncoder(device:h.device,precision:.float32)
        let source=try h.texture(width:8,height:8,value:0.5)
        var c=DeviceCorrection();c.whiteBalance.destination=Chromaticity(x:0.3457,y:0.3585)
        let prepared=try encoder.prepareCorrection(c),digest=try c.effectDigest()
        c.matrix.values=[0,0,1,0,1,0,1,0,0]
        XCTAssertEqual(prepared?.digest,digest)
        let cmd=try XCTUnwrap(h.queue.makeCommandBuffer()),done=DispatchSemaphore(value:0)
        let out=try encoder.encode(source,style:encoder.prepare(ResolvedStyle(profile:.standard)),correction:prepared,request:RenderRequest(input:InputDescriptor(width:8,height:8)),commandBuffer:cmd)
        cmd.addCompletedHandler{_ in done.signal()};cmd.commit();done.wait();XCTAssertNil(cmd.error)
        let x=0.3457/0.3585,z=(1-0.3457-0.3585)/0.3585,gray=pow((0.5+0.055)/1.055,2.4)
        let xyzRGB=[3.2409699419*x-1.5373831776-0.4986107603*z,-0.9692436363*x+1.8759675015+0.0415550574*z,0.0556300797*x-0.2039769589+1.0569715142*z]
        let expected=xyzRGB.map{1.055*pow($0*gray,1/2.4)-0.055}
        for (a,b) in zip(RenderHarness.read(out).prefix(3),expected) {XCTAssertEqual(Double(a),b,accuracy:1e-5)}
    }
    private func run(_ h:RenderHarness,source:MTLTexture,correction:DeviceCorrection?,profile:Profile = .standard,limit:Int?=nil,lut:LUTAsset?=nil) throws -> MTLTexture {
        let cmd=try XCTUnwrap(h.queue.makeCommandBuffer()),done=DispatchSemaphore(value:0)
        var request=RenderRequest(input:InputDescriptor(width:source.width,height:source.height));request.maximumLongEdge=limit
        let result=try h.encoder.encode(source,style:h.encoder.prepare(ResolvedStyle(profile:profile)),correction:h.encoder.prepareCorrection(correction,lut:lut),request:request,commandBuffer:cmd)
        cmd.addCompletedHandler{_ in done.signal()};cmd.commit();done.wait();XCTAssertNil(cmd.error);return result
    }
    private func cube(square:Bool)->LUTAsset {
        var lines=["LUT_3D_SIZE 3"]
        for b in 0...2 {for g in 0...2 {for r in 0...2 {lines.append([r,g,b].map {let v=Double($0)/2;return String(square ? v*v:v)}.joined(separator:" "))}}}
        return LUTAsset(name:"same name",cubeText:lines.joined(separator:"\n"))
    }
}
