import XCTest
import Metal
import ImagingCore
@testable import ImageRendering
@testable import ImageAnalysis

final class CameraEffectsTests:XCTestCase {
    private var neutral:Profile {Profile.standard}
    func testNewSchemaRoundTripAndValidation() throws {
        var p=neutral;p.parameters.tone.enabled=true;p.parameters.tone.curve = .init(knots:zip([0.0,0.25,0.5,0.75,1],[0,0.1,0.5,0.75,1]).map{.init(x:$0,y:$1)},interpolation:.smooth);p.parameters.softening.enabled=true;p.parameters.softening.amount=0.3
        p.parameters.grain.enabled=true;p.parameters.grain.amount=0.02;p.parameters.halation.enabled=true;p.parameters.halation.amount=0.2
        XCTAssertEqual(try JSONDecoder().decode(Profile.self,from:JSON.encode(p)),p)
        p.parameters.tone.curve = .init(knots:zip([0.0,0.25,0.5,0.75,1],[0,0.9,0.5,0.75,1]).map{.init(x:$0,y:$1)},interpolation:.smooth);XCTAssertThrowsError(try p.validate())
        p=neutral;p.parameters.grain.size = .nan;XCTAssertThrowsError(try p.validate())
        p=neutral;p.parameters.halation.red=1.1;XCTAssertThrowsError(try p.validate())
        var json=try XCTUnwrap(JSONSerialization.jsonObject(with:JSON.encode(neutral)) as? [String:Any])
        json["schemaVersion"]=1
        XCTAssertThrowsError(try JSONDecoder().decode(Profile.self,from:JSONSerialization.data(withJSONObject:json)))
        json["schemaVersion"]=2;json.removeValue(forKey:"grain")
        XCTAssertThrowsError(try JSONDecoder().decode(Profile.self,from:JSONSerialization.data(withJSONObject:json)))
    }
    func testInactiveEffectsAreIdentityWithoutExtraDispatches() throws {
        let renderer=try MetalRenderer(),input=try Fixtures.make(.patches,width:96,height:64)
        let baseline=try renderer.renderStyle(input,profile:neutral).image,dispatches=renderer.lastWork.dispatches
        var p=neutral;p.parameters.tone.enabled=true;p.parameters.softening.enabled=true;p.parameters.grain.enabled=true;p.parameters.halation.enabled=true
        let identity=try renderer.renderStyle(input,profile:p).image
        XCTAssertEqual(identity.pixels,baseline.pixels)
        XCTAssertEqual(renderer.lastWork.dispatches,dispatches)
    }
    func testToneCurveIsMonotoneAndKeepsNeutralGreys() throws {
        var pixels=[Float]()
        for _ in 0..<8 {for x in 0..<257 {let y=Float(x)/256;pixels += [y,y,y,1]}}
        let input=try ImageFrame(width:257,height:8,pixels:pixels)
        for points:[Double] in [[0.03,0.1,0.5,0.9,0.98],[0,0,0.1,1,1],[0.5,0.5,0.5,0.5,0.5]] {
            var p=neutral;p.parameters.tone.enabled=true
            p.parameters.tone.curve = .init(knots:zip([0.0,0.25,0.5,0.75,1],points).map{.init(x:$0,y:$1)},interpolation:.smooth)
            let out=try MetalRenderer().renderStyle(input,profile:p).image
            XCTAssertEqual(out.pixels[0],Float(points[0]),accuracy:0.00002)
            XCTAssertEqual(out.pixels[256*4],Float(points[4]),accuracy:0.00002)
            for x in 1..<257 {
                XCTAssertGreaterThanOrEqual(out.pixels[x*4]+0.000001,out.pixels[(x-1)*4])
                XCTAssertEqual(out.pixels[x*4],out.pixels[x*4+1],accuracy:0.000001)
            }
        }
    }
    func testSofteningSmoothsRGBEdgesAndPreservesFlatFields() throws {
        var pixels=[Float]()
        for _ in 0..<32 {for x in 0..<512 {pixels += [x<256 ? 0:1,0.2,0.7,1]}}
        var p=neutral;p.parameters.softening.enabled=true;p.parameters.softening.amount=1;p.parameters.softening.sigma=8
        let renderer=try MetalRenderer(),out=try renderer.renderStyle(ImageFrame(width:512,height:32,pixels:pixels),profile:p).image
        XCTAssertGreaterThan(out.pixels[(16*512+255)*4],0.1)
        XCTAssertLessThan(out.pixels[(16*512+256)*4],0.99)
        let flat=try renderer.renderStyle(ImageFrame.solid(width:64,height:64,value:0.4),profile:p).image
        XCTAssertEqual(flat.pixels[0],0.4,accuracy:0.00002)
    }
    func testHalationAddsTintAroundBrightSourcesOnly() throws {
        var pixels=[Float](repeating:0,count:257*257*4)
        for i in stride(from:3,to:pixels.count,by:4){pixels[i]=1}
        for y in 126...130 {for x in 126...130 {for c in 0..<3 {pixels[(y*257+x)*4+c]=1}}}
        var p=neutral;p.parameters.halation.enabled=true;p.parameters.halation.amount=0.8;p.parameters.halation.sigma=32
        let renderer=try MetalRenderer(),out=try renderer.renderStyle(ImageFrame(width:257,height:257,pixels:pixels),profile:p).image
        let index=(128*257+133)*4
        XCTAssertGreaterThan(out.pixels[index],0.01)
        XCTAssertGreaterThan(out.pixels[index],out.pixels[index+1])
        XCTAssertGreaterThan(out.pixels[index+1],out.pixels[index+2])
        for value:Float in [0,0.3,0.9] {
            let flat=try renderer.renderStyle(ImageFrame.solid(width:128,height:128,value:value),profile:p).image
            XCTAssertEqual(flat.pixels[0],value,accuracy:0.0002)
        }
    }
    func testFilmGrainHasStableSeedAndControllableScale() throws {
        let frame=try ImageFrame.solid(width:512,height:256,value:0.5),renderer=try MetalRenderer()
        var p=neutral;p.parameters.grain.enabled=true;p.parameters.grain.amount=0.03;p.parameters.grain.chroma=0;p.parameters.grain.roughness=0
        let a=try renderer.renderStyle(frame,profile:p).image
        XCTAssertEqual(a.pixels,try renderer.renderStyle(frame,profile:p).image.pixels)
        let grey=stride(from:0,to:a.pixels.count,by:4).map{Double(a.pixels[$0])}
        XCTAssertEqual(grey.reduce(0,+)/Double(grey.count),0.5,accuracy:0.003)
        XCTAssertGreaterThan(grey.map{($0-0.5)*($0-0.5)}.reduce(0,+)/Double(grey.count),0.0004)
        XCTAssertNotEqual(a.pixels,try renderer.renderStyle(frame,profile:p,seed:43).image.pixels)
        func gradient(_ image:ImageFrame)->Double {
            var total=0.0
            for y in 0..<image.height {for x in 1..<image.width {total+=abs(Double(image.pixels[(y*image.width+x)*4]-image.pixels[(y*image.width+x-1)*4]))}}
            return total/Double(image.width*image.height)
        }
        p.parameters.grain.size=8
        XCTAssertLessThan(gradient(try renderer.renderStyle(frame,profile:p).image),gradient(a)*0.65)
    }



    func testMaximumEffectsRemainFiniteAndOpaque() throws {
        var p=neutral;p.parameters.tone.enabled=true;p.parameters.color.exposureEV=3
        p.parameters.tone.curve = .init(knots:zip([0.0,0.25,0.5,0.75,1],[0.1,0.1,0.9,1,1]).map{.init(x:$0,y:$1)},interpolation:.smooth)
        p.parameters.softening.enabled=true;p.parameters.softening.amount=1;p.parameters.softening.sigma=8
        p.parameters.halation.enabled=true;p.parameters.halation.amount=1;p.parameters.halation.sigma=32;p.parameters.halation.threshold=0;p.parameters.halation.knee=0.5
        p.parameters.grain.enabled=true;p.parameters.grain.amount=0.1;p.parameters.grain.size=0.5;p.parameters.grain.roughness=1;p.parameters.grain.chroma=1
        let output=try MetalRenderer().renderStyle(Fixtures.make(.patches,width:257,height:193),profile:p).image
        for i in output.pixels.indices {
            XCTAssertTrue(output.pixels[i].isFinite && (0...1).contains(output.pixels[i]))
            if i%4==3 {XCTAssertEqual(output.pixels[i],1)}
        }
    }

    private func upload(_ frame:ImageFrame,device:MTLDevice) throws -> MTLTexture {
        let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba32Float,width:frame.width,height:frame.height,mipmapped:false)
        d.storageMode = .shared;d.usage=[.shaderRead,.shaderWrite]
        let texture=try XCTUnwrap(device.makeTexture(descriptor:d))
        frame.pixels.withUnsafeBytes{texture.replace(region:MTLRegionMake2D(0,0,frame.width,frame.height),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:frame.width*16)}
        return texture
    }
}
