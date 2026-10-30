import XCTest
import CoreImage
import ImagingCore
import ImageRendering
@testable import ImageAnalysis

final class RAWImportTests:XCTestCase {
    func testRAWImportGeometryPreservesNativeSize() throws {
        XCTAssertEqual(try RAWImportGeometry.size(width:4032,height:3024).width,4032)
        for (w,h) in [(8064,6048),(9504,6336),(20000,4000),(6048,8064)] {
            let size=try RAWImportGeometry.size(width:Double(w),height:Double(h))
            XCTAssertEqual(size.width,w)
            XCTAssertEqual(size.height,h)
            XCTAssertEqual(Double(size.width)/Double(size.height),Double(w)/Double(h),accuracy:0.002)
        }
        XCTAssertThrowsError(try RAWImportGeometry.size(width:.infinity,height:3000))
        XCTAssertThrowsError(try RAWImportGeometry.size(width:0,height:3000))
    }
    func testRAWExtensionsAcceptedAndCorruptInputRejected() throws {
        for ext in ["DNG","nef","arw","cr2","cr3","raf","orf","rw2"] {
            XCTAssertTrue(ImageCodec.supportsInputFile(URL(fileURLWithPath:"/tmp/photo."+ext)),ext)
        }
        XCTAssertFalse(ImageCodec.supportsInputFile(URL(fileURLWithPath:"/tmp/style.json")))
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".dng")
        defer{try? FileManager.default.removeItem(at:url)}
        try Data("invalid raw".utf8).write(to:url)
        XCTAssertThrowsError(try ImageCodec.load(url))
    }
    func testRealRAWDevelopRenderAndExport() throws {
        guard let path=ProcessInfo.processInfo.environment["LUMERA_RAW_TEST_FILE"] else {throw XCTSkip("Set LUMERA_RAW_TEST_FILE to a local RAW photo")}
        let source=URL(fileURLWithPath:path),started=Date()
        let image=try ImageCodec.load(source)
        try image.validateStorage()
        XCTAssertEqual(image.provenance["rawDecoder"],"CIRAWFilter")
        XCTAssertEqual(image.provenance["hdr"],"RAW developed to SDR; extendedDynamicRangeAmount=0")
        XCTAssertTrue(image.pixels.allSatisfy{(0...1).contains($0)})
        for i in stride(from:3,to:image.pixels.count,by:4) {if image.pixels[i] != 1 {XCTFail("nonopaque RAW output");break}}
        let filter=try XCTUnwrap(CIRAWFilter(imageURL:source))
        let orientation=filter.orientation.rawValue
        if (5...8).contains(orientation) {
            XCTAssertEqual(Double(image.width)/Double(image.height),filter.nativeSize.height/filter.nativeSize.width,accuracy:0.002)
        }
        let renderer=try MetalRenderer(),request=RenderRequest(input:image.descriptor,maximumLongEdge:1280)
        let style=try ResolvedStyle(profile:StylePresets.make("film-demo"))
        let rendered=try renderer.render(image,style:style,request:request)
        let output=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".png")
        defer{try? FileManager.default.removeItem(at:output)}
        try ImageCodec.encodeReference(rendered.image).write(to:output)
        let reloaded=try ImageCodec.load(output)
        XCTAssertEqual(reloaded.width,rendered.image.width)
        XCTAssertLessThan(zip(reloaded.pixels,rendered.image.pixels).map{abs($0-$1)}.max()!,0.0001)
        print("RAW roundtrip \(source.lastPathComponent): \(image.width)x\(image.height), decoder \(image.provenance["rawDecoderVersion"] ?? "?"), total \(Date().timeIntervalSince(started)) s")
    }
}
