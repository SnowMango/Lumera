import XCTest
import Foundation
import ImageIO
import ImagingCore
@testable import ImageAnalysis

final class AcceptanceFixturesTests:XCTestCase {
    func testIndependentReferenceAtHandCheckedValues() {
        XCTAssertEqual(AcceptanceReference.decode(0.04045),0.00313080495356037,accuracy:1e-14)
        XCTAssertEqual(AcceptanceReference.exposure(0.5,ev:1),0.685836119064369,accuracy:1e-12)
        XCTAssertEqual(AcceptanceReference.linear(0.25,knots:[(0,0),(0.5,0.2),(1,1)]),0.1)
        XCTAssertEqual(AcceptanceReference.monotone(0.25,knots:[(0,0),(0.5,0.2),(1,1)]),0.085,accuracy:1e-12)
        XCTAssertEqual(AcceptanceReference.vignetteEV(x:0,y:0,width:200,height:100,amount:1,start:0.35,falloff:1.5),1,accuracy:1e-12)
        XCTAssertEqual(AcceptanceReference.gaussian([0.5,0.5,0.5,0.5],width:2,height:2,sigma:1),[0.5,0.5,0.5,0.5])
    }
    func testIndependentKnownValuesAndNoiseRepeatability() throws {
        let ramp=try AcceptanceFixtures.make(.ramp,width:65,height:49)
        XCTAssertEqual(ramp.pixels[32*4],0.5)
        let flat=try AcceptanceFixtures.make(.flat18,width:65,height:49)
        XCTAssertEqual(flat.pixels[0],0.18,accuracy:0.000001)
        let a=try AcceptanceFixtures.make(.noise,width:257,height:193,seed:42)
        XCTAssertEqual(a.pixels,try AcceptanceFixtures.make(.noise,width:257,height:193,seed:42).pixels)
        XCTAssertNotEqual(a.pixels,try AcceptanceFixtures.make(.noise,width:257,height:193,seed:43).pixels)
        let samples=stride(from:0,to:a.pixels.count,by:4).map{Double(a.pixels[$0])-0.5}
        XCTAssertEqual(samples.reduce(0,+)/Double(samples.count),0,accuracy:0.0004)
        XCTAssertEqual(sqrt(samples.reduce(0){$0+$1*$1}/Double(samples.count)),0.02,accuracy:0.0004)
    }
    func testKitHasVerifiableFilesROIsAndOpaque16BitSRGB() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:dir)}
        let manifest=try AcceptanceFixtures.write(to:dir)
        XCTAssertEqual(manifest.version,"lumera-acceptance-v1")
        for entry in manifest.images {
            let url=dir.appendingPathComponent(entry.file),data=try Data(contentsOf:url)
            XCTAssertEqual(Digest.data(data),entry.sha256)
            XCTAssertEqual(data[24],16);XCTAssertEqual(data[25],2) // PNG IHDR: RGB, no alpha
            let source=try XCTUnwrap(CGImageSourceCreateWithData(data as CFData,nil))
            let image=try XCTUnwrap(CGImageSourceCreateImageAtIndex(source,0,nil))
            XCTAssertEqual(image.width,2048);XCTAssertEqual(image.height,1536)
            XCTAssertNotNil(image.colorSpace)
            for roi in entry.regions {XCTAssertTrue(roi.x>=0 && roi.y>=0 && roi.width>0 && roi.height>0 && roi.x+roi.width<=2048 && roi.y+roi.height<=1536)}
            XCTAssertTrue(["D01-tone","D02-color","D03-flat","D04-detail","D05-glow","D06-noise"].contains(entry.method))
            // PNG carries a real sRGB declaration, not just an arbitrary nonnil color space.
            var offset=8,foundSRGB=false
            while offset+12<=data.count {
                let length=data[offset..<offset+4].reduce(0){($0<<8)|Int($1)}
                let tag=String(decoding:data[offset+4..<offset+8],as:UTF8.self)
                if tag=="sRGB" {foundSRGB=true}
                offset+=12+length
            }
            XCTAssertTrue(foundSRGB)
            if entry.kind == .patches {XCTAssertEqual(entry.regions.count,12)}
            if entry.kind == .steps {
                XCTAssertEqual(entry.regions.count,21)
                for (i,roi) in entry.regions.enumerated() {
                    XCTAssertEqual(roi.x*21/2048,i);XCTAssertEqual((roi.x+roi.width-1)*21/2048,i)
                }
            }
            if entry.kind == .flat50 {XCTAssertEqual(entry.regions.count,6)}
            if entry.kind == .ramp {XCTAssertTrue(entry.regions.contains{$0.x==0 && $0.width==2048})}
            if entry.kind == .patches {
                for roi in entry.regions {
                    XCTAssertEqual(roi.width,128);XCTAssertEqual(roi.height,128)
                    XCTAssertEqual(roi.x*4/2048,(roi.x+roi.width-1)*4/2048)
                    XCTAssertEqual(roi.y*3/1536,(roi.y+roi.height-1)*3/1536)
                }
            }
            if entry.kind == .ramp {
                let frame=try ImageCodec.load(url)
                XCTAssertEqual(frame.pixels[1024*4],Float(1024.0/2047),accuracy:0.00004)
            }
        }
        for asset in manifest.assets {
            XCTAssertEqual(Digest.data(try Data(contentsOf:dir.appendingPathComponent(asset.file))),asset.sha256)
        }
        let saved=try JSON.load(FixtureManifest.self,from:dir.appendingPathComponent("manifest.json"))
        XCTAssertEqual(saved,manifest)
        // Existing material cannot be silently replaced.
        XCTAssertThrowsError(try AcceptanceFixtures.write(to:dir))
        let image=try AcceptanceFixtures.make(.ramp)
        XCTAssertEqual(try ImageCodec.encodeReference(image),try Data(contentsOf:dir.appendingPathComponent("digital/ramp.png")))
    }
}
