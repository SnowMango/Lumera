import XCTest
import ImagingCore
import ImageRendering
@testable import ImageAnalysis

final class PreviewInputReuseTests:XCTestCase {
    func testFailedReplacementRenderPreservesCompletedInputAndEffects() throws {
        let renderer=try MetalRenderer(),image=try Fixtures.make(.texture,width:960,height:720)
        let style=try ResolvedStyle(profile:StylePresets.make("film-demo"))
        let request=RenderRequest(input:image.descriptor,maximumLongEdge:640)
        let first=try renderer.render(image,style:style,request:request)
        let bad=LUTAsset(name:"invalid",cubeText:"not a cube")
        XCTAssertThrowsError(try renderer.renderPreview(image,style:style,resources:.init(lut:bad),request:request))
        let next=try renderer.render(image,style:style,request:request)
        XCTAssertEqual(renderer.lastWork.uploads,0,"A failed new render must not discard previously completed input")
        XCTAssertEqual(renderer.lastWork.prefixHits,1,"An uncommitted replacement must not replace completed effects")
        XCTAssertEqual(next.image.pixels,first.image.pixels)
    }
    func testColdFailureNeverReusesUnsubmittedResizeOrCorrection() throws {
        let renderer=try MetalRenderer(),image=try Fixtures.make(.patches,width:193,height:129)
        let request=RenderRequest(input:image.descriptor,maximumLongEdge:96)
        var correction=DeviceCorrection();correction.matrix.values=[0.8,0,0,0,0.9,0,0,0,1]
        let bad=LUTAsset(name:"invalid",cubeText:"not a cube")
        XCTAssertThrowsError(try renderer.renderPreview(image,style:ResolvedStyle(profile:.standard),correction:correction,resources:.init(lut:bad),request:request))
        let style=try ResolvedStyle(profile:.standard)
        let actual=try renderer.render(image,style:style,correction:correction,request:request)
        XCTAssertEqual(renderer.lastWork.uploads,1)
        let fresh=try MetalRenderer().render(image,style:style,correction:correction,request:request)
        XCTAssertEqual(actual.image.pixels,fresh.image.pixels)
    }
    func testLargePhotoSliderChangesReuseInput() throws {
        let renderer=try MetalRenderer(),image=try ImageFrame.solid(width:4032,height:3024,value:0.4)
        var p=StyleParameters();p.vignette.enabled=true
        let request=RenderRequest(input:image.descriptor,maximumLongEdge:1280)
        for i in 0..<4 {
            p.vignette.amountEV=Double(i)*0.1
            let output=try renderer.renderPreview(image,style:ResolvedStyle(parameters:p),request:request)
            let timing=try XCTUnwrap(output.manifest.timing)
            print("Preview reuse sample \(i): prepMS=\(timing.inputPreparationSeconds*1000) effectsMS=\(timing.effectsSeconds*1000) uploads=\(renderer.lastWork.uploads)")
            XCTAssertEqual(renderer.lastWork.uploads,i==0 ? 1:0)
            XCTAssertEqual(timing.reusedInput,i>0)
        }
    }
}
