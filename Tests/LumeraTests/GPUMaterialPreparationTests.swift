@testable import ImageAnalysis
import XCTest
import ImagingCore
@testable import ImageRendering

final class GPUMaterialPreparationTests:XCTestCase {
    func testOpaqueNormalizationMatchesLegacyPixelsIncludingRoundingBoundaries() throws {
        let renderer=try MetalRenderer()
        var frames=try Fixture.allCases.map{try Fixtures.make($0,width:97,height:65)}
        var values=[Float](repeating:1,count:257*257*4)
        for i in 0..<(257*257) {
            let v=(Float(i%65536)+0.5)/65535
            values[i*4]=v;values[i*4+1]=v.nextDown;values[i*4+2]=v.nextUp
        }
        values[0] = -0.1;values[4]=1.1
        frames.append(try ImageFrame(width:257,height:257,pixels:values))
        for frame in frames {
            let before=frame.digest
            let expected=try ImageCodec.normalizedMaterial(frame)
            let actual=try renderer.prepareReferenceImage(frame)
            XCTAssertTrue(actual.pixels==expected.pixels,"Exact canonical pixel equality is required for evidence and fit comparisons")
            XCTAssertEqual(actual.digest,expected.digest)
            XCTAssertEqual(frame.digest,before)
            XCTAssertGreaterThan(renderer.lastWork.gpuSeconds ?? 0,0)
        }
    }
    func testTransparentNormalizationRetainsLegacyCompositing() throws {
        var frame=try Fixtures.make(.patches,width:97,height:65)
        frame.pixels[3]=0.4;frame.pixels[7]=0;frame.pixels[11]=0.99999
        let expected=try ImageCodec.normalizedMaterial(frame)
        let actual=try MetalRenderer().prepareReferenceImage(frame)
        XCTAssertTrue(actual.pixels==expected.pixels)
    }
    func testCancelledPreparationCannotPopulateTextureCache() async throws {
        let renderer=try MetalRenderer(),input=try Fixtures.make(.patches,width:97,height:65)
        let task=Task {withUnsafeCurrentTask{$0?.cancel()};return try renderer.prepareReferenceImage(input)}
        do{_=try await task.value;XCTFail("cancelled preparation completed")}catch is CancellationError {}catch{XCTFail("unexpected \(error)")}
        XCTAssertEqual(renderer.memoryStatistics["cachedInputs"],"0")
    }
    func testPixelDigestMatchesExistingDataHashAfterMutation() throws {
        var frame=try Fixtures.make(.patches,width:97,height:65)
        for value:Float in [0.123,0.456] {
            frame.pixels[0]=value
            XCTAssertEqual(frame.digest,frame.pixels.withUnsafeBytes{Digest.data(Data($0))})
        }
    }
}
