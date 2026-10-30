import XCTest
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import ImagingCore
import Metal
@testable import ImageRendering

final class LUTDataTests:XCTestCase {
    private func rawData(_ n:Int=3,rgba:Bool=true,blueFastest:Bool=false)->Data {
        var values=[Float]()
        for outer in 0..<n {for g in 0..<n {for inner in 0..<n {
            let r=blueFastest ? outer:inner,b=blueFastest ? inner:outer
            values += [Float(r)/Float(n-1)*0.6,Float(g)/Float(n-1)*0.8,Float(b)/Float(n-1)*0.4]
            if rgba{values.append(1)}
        }}}
        return values.withUnsafeBytes{Data($0)}
    }
    func testRGBAndRGBALayoutsOrdersAndGPUReuse()throws {
        let h=try RenderHarness(precision:.float32)
        var digests=Set<String>()
        for rgba in [true,false] {for blue in [true,false] {
            let asset=try LUTImporter.load(data:rawData(rgba:rgba,blueFastest:blue),descriptor:.init(dimension:3,layout:rgba ? .rgbaFloat32:.rgbFloat32,order:blue ? .blueFastest:.redFastest),name:"App LUT")
            digests.insert(asset.sha256)
            let result=try h.render(.standard,width:1,height:1,lut:asset)
            XCTAssertEqual(result[0],0.3,accuracy:0.0001)
            XCTAssertEqual(result[1],0.4,accuracy:0.0001)
            XCTAssertEqual(result[2],0.2,accuracy:0.0001)
        }}
        XCTAssertEqual(digests.count,1)
        XCTAssertEqual(h.encoder.staticResourceStatistics.lutUploads,1)
    }
    func testRawCubeValidationAndUnalignedData()throws {
        let data=rawData(2),d=LUTDataDescriptor(dimension:2,layout:.rgbaFloat32)
        let a=try LUTImporter.load(data:data,descriptor:d,name:"a")
        var padded=Data([0]);padded.append(data)
        XCTAssertEqual(a.sha256,try LUTImporter.load(data:padded.dropFirst(),descriptor:d,name:"b").sha256)
        XCTAssertThrowsError(try LUTImporter.load(data:data.dropLast(),descriptor:d,name:"bad"))
        XCTAssertThrowsError(try LUTImporter.load(data:data,descriptor:.init(dimension:Int.max,layout:.rgbaFloat32),name:"bad"))
        for (offset,value) in [(0,Float.nan),(0,Float.infinity),(0,Float(-0.1)),(0,Float(1.1)),(12,Float(0.5))] {
            var corrupted=data,number=value
            withUnsafeBytes(of:&number){corrupted.replaceSubrange(offset..<offset+4,with:$0)}
            XCTAssertThrowsError(try LUTImporter.load(data:corrupted,descriptor:d,name:"bad"))
        }
        var changed=a;changed.sha256="bad";XCTAssertThrowsError(try changed.validate())
        changed=a;changed.cubeText="LUT_3D_SIZE 2";XCTAssertThrowsError(try changed.validate())
    }
    func testRawCubeAllows128WithoutFileSizeLimit()throws {
        var values=[Float](repeating:0,count:128*128*128*4)
        for i in stride(from:3,to:values.count,by:4){values[i]=1}
        let data=values.withUnsafeBytes{Data($0)}
        XCTAssertGreaterThan(data.count,16_000_000)
        let asset=try LUTImporter.load(data:data,descriptor:.init(dimension:128,layout:.rgbaFloat32),name:"128")
        try asset.validate();XCTAssertEqual(try asset.decodedCube().size,128)
    }
    func testCubeFileBytesAndURLAgree()throws {
        let text=IndependentLUTTests.asset(0.5).cubeText,data=Data(text.utf8)
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".cube")
        defer{try? FileManager.default.removeItem(at:url)}
        try data.write(to:url)
        XCTAssertEqual(try LUTImporter.load(data:data,format:.cube,name:url.lastPathComponent),try LUTImporter.load(url))
        XCTAssertThrowsError(try LUTImporter.load(data:Data([0xff]),format:.cube,name:"Bad"))
        XCTAssertThrowsError(try LUTImporter.load(data:data,format:.tiledPNG,name:"Bad"))
    }
    func testPNGFileBytesAndURLAgree()throws {
        let pixels=Data(repeating:128,count:512*512*4)
        let provider=try XCTUnwrap(CGDataProvider(data:pixels as CFData))
        let image=try XCTUnwrap(CGImage(width:512,height:512,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:512*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.noneSkipLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
        let data=NSMutableData()
        let destination=try XCTUnwrap(CGImageDestinationCreateWithData(data,UTType.png.identifier as CFString,1,nil))
        CGImageDestinationAddImage(destination,image,nil);XCTAssertTrue(CGImageDestinationFinalize(destination))
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".png")
        defer{try? FileManager.default.removeItem(at:url)}
        try (data as Data).write(to:url)
        XCTAssertEqual(try LUTImporter.load(data:data as Data,format:.tiledPNG,name:url.lastPathComponent),try LUTImporter.load(url))
    }
}
