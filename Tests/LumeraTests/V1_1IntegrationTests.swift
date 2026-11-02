import XCTest
import CoreImage
import ImagingCore
import ImageRendering

final class V1_1IntegrationTests: XCTestCase {
    func testTwelveMegapixelFrozenStyleAtTileBoundaries() async throws {
        let bounds = CGRect(x:0,y:0,width:4000,height:3000)
        let gradient = try XCTUnwrap(CIFilter(name:"CILinearGradient",parameters:[
            "inputPoint0":CIVector(x:0,y:0),"inputPoint1":CIVector(x:4000,y:3000),
            "inputColor0":CIColor(red:0.1,green:0.4,blue:0.2),"inputColor1":CIColor(red:1,green:1,blue:0.8)
        ])?.outputImage).cropped(to:bounds)
        var p = try StylePresets.make("film-demo")
        p.responses = [.init(target:.halationRadius,axis:.iso,operation:.replace,
                             curve:.init(knots:[.init(x:100,y:2),.init(x:1600,y:9)]))]
        let roundTrip = try ProfileCodec.decode(ProfileCodec.encode(p))
        var conditions = CaptureConditions(); conditions.iso = 400
        let frozen = try StyleEvaluator.freeze(roundTrip,conditions:conditions)
        let evaluated = try StyleEvaluator.evaluate(StyleEvaluator.compile(roundTrip),conditions:conditions).resolvedStyle()
        XCTAssertEqual(try ResolvedStyle(profile:frozen).effectiveDigest,evaluated.effectiveDigest)
        let renderer = try LumeraRenderer(), style = try renderer.prepare(frozen)
        var options = RenderOptions(seed:119,frameIndex:2); options.glowScale = .quarter; options.halationScale = .half
        let full = try await renderer.render(gradient,style:style,options:options)
        let budget = 64 * 1024 * 1024
        let tiled = try await renderer.renderTiled(gradient,style:style,options:options,workingMemoryLimit:budget)
        XCTAssertEqual(tiled.extent,bounds)
        let context = CIContext(options:[.cacheIntermediates:false]), space = CGColorSpace(name:CGColorSpace.sRGB)!
        for rect in [CGRect(x:0,y:0,width:17,height:19),CGRect(x:2043,y:2043,width:17,height:19),CGRect(x:3979,y:2979,width:17,height:19)] {
            func pixels(_ im: CIImage) -> [Float] {
                var data = [Float](repeating:0,count:17*19*4)
                data.withUnsafeMutableBytes { context.render(im,toBitmap:$0.baseAddress!,rowBytes:17*16,bounds:rect,format:.RGBAf,colorSpace:space) }
                return data
            }
            XCTAssertLessThanOrEqual(zip(pixels(full),pixels(tiled)).map { abs($0-$1) }.max()!,0.002)
        }
    }
}
