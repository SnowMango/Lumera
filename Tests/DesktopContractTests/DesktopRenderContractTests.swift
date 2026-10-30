import XCTest
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import ImagingCore
import ImageRendering
@testable import ImageAnalysis

final class DesktopRenderContractTests:XCTestCase {
    func testCombinedTextureAndDesktopSameSizeAgreement() throws {
        let d=try XCTUnwrap(MTLCreateSystemDefaultDevice()),queue=try XCTUnwrap(d.makeCommandQueue()),encoder=try TextureEffectEncoder(device:d)
        let image=try Fixtures.make(.patches,width:257,height:193)
        var p=TestProfiles.ccd
        p.parameters.color.exposureEV=0.1;p.parameters.color.whiteBalance.destination=Chromaticity(x:0.3457,y:0.3585)
        p.parameters.tone.enabled=true;p.parameters.tone.curve = .init(knots:zip([0.0,0.25,0.5,0.75,1],[0,0.18,0.5,0.75,1]).map{.init(x:$0,y:$1)},interpolation:.smooth)
        p.parameters.softening.enabled=true;p.parameters.softening.amount=0.4;p.parameters.softening.sigma=4
        p.parameters.halation.enabled=true;p.parameters.halation.amount=0.2;p.parameters.halation.threshold=0.3
        p.parameters.grain.enabled=true;p.parameters.grain.amount=0.02;p.parameters.grain.size=6
        let style=try ResolvedStyle(profile:p),request=RenderRequest(input:image.descriptor)
        let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba32Float,width:image.width,height:image.height,mipmapped:false)
        descriptor.storageMode = .shared;descriptor.usage=[.shaderRead,.shaderWrite]
        let input=try XCTUnwrap(d.makeTexture(descriptor:descriptor))
        image.pixels.withUnsafeBytes{input.replace(region:MTLRegionMake2D(0,0,image.width,image.height),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:image.width*16)}
        let command=try XCTUnwrap(queue.makeCommandBuffer()),done=DispatchSemaphore(value:0)
        let texture=try encoder.encode(input,style:encoder.prepare(style),request:request,commandBuffer:command)
        command.addCompletedHandler{_ in done.signal()};command.commit();done.wait();XCTAssertNil(command.error)
        var actual=[Float16](repeating:0,count:image.pixels.count)
        actual.withUnsafeMutableBytes{texture.getBytes($0.baseAddress!,bytesPerRow:image.width*8,from:MTLRegionMake2D(0,0,image.width,image.height),mipmapLevel:0)}
        let expected=try MetalRenderer().render(image,style:style,request:request).image.pixels
        XCTAssertLessThan(zip(actual.map(Float.init),expected).map{abs($0-$1)}.max() ?? 1,0.006)
    }
    func testMeasurementCacheCannotBypassOpaqueRenderingContract() throws {
        var image=try ImageFrame.solid(width:64,height:64,value:0.5);image.pixels[3]=0.5
        let renderer=try MetalRenderer()
        _=try renderer.measureFeatureStatistics(image,kind:.noise)
        XCTAssertThrowsError(try renderer.render(image,style:ResolvedStyle(profile:.standard),request:RenderRequest(input:image.descriptor)))
    }
    func testReferenceAndMeasurementCannotRelabelUnsupportedColor() throws {
        let renderer=try MetalRenderer()
        for transfer in [InputDescriptor.Transfer.linear,.pq,.hlg] {
            var image=try ImageFrame.solid(width:64,height:64,value:0.5);image.descriptor.transfer=transfer
            XCTAssertThrowsError(try renderer.prepareReferenceImage(image))
            XCTAssertThrowsError(try ImageCodec.normalizedMaterial(image))
            XCTAssertThrowsError(try renderer.measureFeatureStatistics(image,kind:.noise))
            XCTAssertThrowsError(try MeasurementEngine.measure(image,kind:.noise))
        }
        var image=try ImageFrame.solid(width:64,height:64,value:0.5);image.descriptor.primaries = .displayP3
        XCTAssertThrowsError(try renderer.prepareReferenceImage(image))
        XCTAssertThrowsError(try ImageCodec.encodeReference(image))
        image.descriptor.primaries = .sRGB;image.pixels.removeLast()
        XCTAssertThrowsError(try renderer.prepareReferenceImage(image))
    }
    func testExplicitInputContractAndReferenceExports() throws {
        var image=try Fixtures.make(.patches,width:64,height:48)
        let renderer=try MetalRenderer(),style=try ResolvedStyle(profile:.standard)
        var request=RenderRequest(input:image.descriptor)
        request.input.transfer = .pq
        XCTAssertThrowsError(try renderer.render(image,style:style,request:request))
        request=RenderRequest(input:image.descriptor)
        image.pixels[3]=0.5
        XCTAssertThrowsError(try renderer.render(image,style:style,request:request))
        image.pixels[3]=1
        let output=try renderer.render(image,style:style,request:request)
        XCTAssertEqual(output.image.pixels,image.pixels)
        for (data,depth) in [(try ImageCodec.encodePhoto(output.image,format:.png),8),(try ImageCodec.encodeReference(output.image),16)] {
            let source=try XCTUnwrap(CGImageSourceCreateWithData(data as CFData,nil))
            let cg=try XCTUnwrap(CGImageSourceCreateImageAtIndex(source,0,nil))
            XCTAssertEqual(cg.bitsPerComponent,depth)
            XCTAssertTrue([CGImageAlphaInfo.none,.noneSkipFirst,.noneSkipLast].contains(cg.alphaInfo))
        }
    }
    func testColorAndRequestChangesInvalidateReuse() throws {
        let image=try Fixtures.make(.patches,width:129,height:97),renderer=try MetalRenderer()
        var p=Profile.standard
        let request=RenderRequest(input:image.descriptor)
        _=try renderer.render(image,style:ResolvedStyle(profile:p),request:request)
        p.parameters.color.exposureEV=0.3
        p.parameters.color.whiteBalance.destination=Chromaticity(x:0.3457,y:0.3585)
        p.parameters.color.matrix.values=[0,1,0,0,0,1,1,0,0]
        var final=p.parameters;final.color.exposureEV -= 0.2
        let style=try ResolvedStyle(parameters:final,profileDigest:p.effectDigest())
        let cached=try renderer.render(image,style:style,request:request)
        let fresh=try MetalRenderer().render(image,style:style,request:request)
        XCTAssertEqual(cached.image.pixels,fresh.image.pixels)
        XCTAssertEqual(cached.manifest.profileDigest,try p.effectDigest())
        XCTAssertEqual(cached.manifest.effectiveDigest,style.effectiveDigest)
        XCTAssertNotEqual(cached.manifest.effectiveDigest,cached.manifest.profileDigest)
        var changed=image;changed.pixels[0]=0.4
        XCTAssertEqual(try renderer.render(changed,style:style,request:request).image.pixels,try MetalRenderer().render(changed,style:style,request:request).image.pixels)
        renderer.releaseCaches();XCTAssertEqual(renderer.cachedBytes,0)
    }
    func testP3ICCIsConvertedAndUntaggedAssumptionIsRecorded() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:dir)}
        let bytes=Data([153,102,51,255]),provider=try XCTUnwrap(CGDataProvider(data:bytes as CFData))
        let cg=try XCTUnwrap(CGImage(width:1,height:1,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:4,
            space:CGColorSpace(name:CGColorSpace.displayP3)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.noneSkipLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.relativeColorimetric))
        let data=NSMutableData(),destination=try XCTUnwrap(CGImageDestinationCreateWithData(data,UTType.png.identifier as CFString,1,nil))
        CGImageDestinationAddImage(destination,cg,nil);XCTAssertTrue(CGImageDestinationFinalize(destination))
        let file=dir.appendingPathComponent("p3.png");try (data as Data).write(to:file)
        let converted=try ImageCodec.load(file)
        XCTAssertEqual(converted.descriptor.primaries,.sRGB)
        XCTAssertTrue(converted.provenance["color"]?.contains("converted") == true)
        XCTAssertGreaterThan(converted.pixels[0],0.62);XCTAssertLessThan(converted.pixels[2],0.18)
        // Remove color chunks to create a genuinely untagged input; preserve PNG chunk CRCs.
        let original=data as Data;var stripped=Data(original.prefix(8)),offset=8
        while offset+12<=original.count {
            let length=original[offset..<offset+4].reduce(0){($0<<8)|Int($1)}
            let type=String(data:original[offset+4..<offset+8],encoding:.ascii)!
            if !["iCCP","sRGB","gAMA","cHRM","cICP"].contains(type) {stripped.append(original[offset..<offset+12+length])}
            offset += 12+length
        }
        let untagged=dir.appendingPathComponent("untagged.png");try stripped.write(to:untagged)
        let untaggedFrame=try ImageCodec.load(untagged)
        XCTAssertTrue(untaggedFrame.provenance["color"]?.contains("assumed sRGB") == true,"\(untaggedFrame.provenance)")
    }
    func testPreviewTextureRemainsImmutableAcrossFurtherRenders() throws {
        let image=try Fixtures.make(.patches,width:129,height:97),renderer=try MetalRenderer()
        let request=RenderRequest(input:image.descriptor,maximumLongEdge:64)
        let first=try renderer.renderPreview(image,style:ResolvedStyle(profile:.standard),request:request)
        func read(_ t:MTLTexture)->[UInt8] {
            var bytes=[UInt8](repeating:0,count:t.width*t.height*4)
            bytes.withUnsafeMutableBytes{t.getBytes($0.baseAddress!,bytesPerRow:t.width*4,from:MTLRegionMake2D(0,0,t.width,t.height),mipmapLevel:0)}
            return bytes
        }
        let before=read(first.texture)
        var p=Profile.standard;p.parameters.color.exposureEV=1
        _=try renderer.renderPreview(image,style:ResolvedStyle(profile:p),request:request)
        renderer.releaseCaches();XCTAssertEqual(before,read(first.texture))
        XCTAssertEqual(first.manifest.width,64);XCTAssertEqual(first.manifest.timing?.readbackSeconds,0)
    }
}
