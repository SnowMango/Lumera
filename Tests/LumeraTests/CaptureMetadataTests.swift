import XCTest
import ImageIO
import ImagingCore
@testable import ImageAnalysis

final class CaptureMetadataTests:XCTestCase {
    func testReadsCaptureQuantitiesButDoesNotInventTemperatureOrDuv() {
        let properties:[CFString:Any]=[kCGImagePropertyExifDictionary:[kCGImagePropertyExifISOSpeedRatings:[400],kCGImagePropertyExifExposureTime:0.008,kCGImagePropertyExifExposureBiasValue: -1.0,kCGImagePropertyExifWhiteBalance:1]]
        let c=CaptureMetadataReader.read(properties:properties)
        XCTAssertEqual(c.iso,400);XCTAssertEqual(c.exposureDurationSeconds,0.008);XCTAssertEqual(c.exposureBiasEV,-1)
        XCTAssertNil(c.whiteBalanceTemperatureKelvin);XCTAssertNil(c.whiteBalanceTintDuv)
        let invalid:[CFString:Any]=[kCGImagePropertyExifDictionary:[kCGImagePropertyExifISOSpeedRatings:[0],kCGImagePropertyExifExposureTime: -1,kCGImagePropertyExifExposureBiasValue:Double.nan]]
        XCTAssertEqual(CaptureMetadataReader.read(properties:invalid),CaptureConditions())
    }
    func testImportAndNormalizationPreserveMetadata() throws {
        let frame=try ImageFrame.solid(width:32,height:24,value:0.5),image=try ImageCodec.photoCGImage(frame)
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".jpg")
        defer{try? FileManager.default.removeItem(at:url)}
        let destination=try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,"public.jpeg" as CFString,1,nil))
        CGImageDestinationAddImage(destination,image,[kCGImagePropertyExifDictionary:[kCGImagePropertyExifISOSpeedRatings:[200],kCGImagePropertyExifExposureTime:0.01]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let loaded=try ImageCodec.load(url)
        XCTAssertEqual(loaded.captureConditions.iso,200)
        XCTAssertEqual(loaded.captureConditions.exposureDurationSeconds,0.01)
        XCTAssertEqual(try ImageCodec.normalizedMaterial(loaded).captureConditions,loaded.captureConditions)
    }
}
