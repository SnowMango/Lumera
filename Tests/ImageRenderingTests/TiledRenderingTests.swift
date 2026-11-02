import XCTest
import CoreImage
import ImagingCore
@testable import ImageRendering

final class TiledRenderingTests: XCTestCase {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    private func source(width: Int = 257, height: Int = 193) -> CIImage {
        var pixels = [Float]()
        for y in 0..<height { for x in 0..<width {
            pixels += [Float((x * 7 + y * 3) % 53) / 52, Float(y) / Float(height), Float(x) / Float(width), 1]
        }}
        return pixels.withUnsafeBytes { CIImage(bitmapData: Data($0), bytesPerRow: width*16,
            size: CGSize(width:width,height:height), format:.RGBAf, colorSpace:space) }
    }

    private func values(_ image: CIImage, _ region: CGRect, context: CIContext) -> [Float] {
        var result = [Float](repeating: 0, count: Int(region.width * region.height) * 4)
        result.withUnsafeMutableBytes { context.render(image, toBitmap: $0.baseAddress!, rowBytes:Int(region.width)*16,
            bounds:region, format:.RGBAf, colorSpace:space) }
        return result
    }

    func testTilesAndRegionMatchFullImageAcrossOpticsAndResize() async throws {
        let renderer = try LumeraRenderer(precision:.float32)
        let source = source()
        var p = try StylePresets.make("film-demo")
        p.parameters.noise.enabled=true; p.parameters.vignette.enabled=true; p.parameters.vignette.amountEV=2
        p.parameters.softening.enabled=true; p.parameters.softening.amount=0.4
        p.parameters.glow.enabled=true; p.parameters.glow.amount=0.7
        p.parameters.halation.enabled=true; p.parameters.halation.threshold=0.25
        let prepared = try renderer.prepare(p)
        var correction = DeviceCorrection()
        correction.matrix.values[0] = 1.12
        let fixedCorrection = try renderer.prepareCorrection(correction,lut:IndependentLUTTests.asset(0.85))
        for limit: Int? in [nil,201] {
            var options = RenderOptions(maximumLongEdge:limit, seed:109, frameIndex:7)
            options.glowScale = .quarter; options.softeningScale = .half; options.halationScale = .eighth
            let full = try await renderer.render(source,style:prepared,options:options,correction:fixedCorrection)
            let tiled = try await renderer.renderTiled(source,style:prepared,options:options,correction:fixedCorrection,workingMemoryLimit:6*1024*1024)
            let rect = CGRect(x:41,y:59,width:109,height:71)
            let roi = try await renderer.renderRegion(source,region:rect,style:prepared,options:options,correction:fixedCorrection)
            for (result, region) in [(tiled,full.extent),(roi,rect)] {
                XCTAssertEqual(result.extent.size,region.size)
                let a = values(full,region,context:renderer.context), b = values(result,result.extent,context:renderer.context)
                let difference = zip(a,b).map { abs($0-$1) }
                XCTAssertLessThanOrEqual(difference.max()!,0.0001,"limit=\(String(describing:limit)), region=\(region); largest at \(difference.firstIndex(of:difference.max()!)!)")
            }
        }
    }

    func testOrientedTranslatedInputAndMetadata() async throws {
        let renderer = try LumeraRenderer(), style = try renderer.prepare(Profile.standard)
        let image = source(width:31,height:19).transformed(by:.init(translationX:12,y:-5))
        let metadata = [kCGImagePropertyExifDictionary as String: [kCGImagePropertyExifISOSpeedRatings as String:[400]]]
        let full = try await renderer.render(image,metadata:metadata,orientation:.right,style:style)
        let region = CGRect(x:2,y:7,width:11,height:17)
        let part = try await renderer.renderRegion(image,region:region,metadata:metadata,orientation:.right,style:style)
        XCTAssertEqual(values(part,part.extent,context:renderer.context),values(full,region,context:renderer.context))
        XCTAssertEqual(part.properties[kCGImagePropertyPixelWidth as String] as? Int,11)
        let exif = part.properties[kCGImagePropertyExifDictionary as String] as? [String:Any]
        XCTAssertEqual(exif?[kCGImagePropertyExifISOSpeedRatings as String] as? [Int],[400])
        let task = Task { try await renderer.renderTiled(image,style:style) }
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled render returned a result") } catch is CancellationError {}
    }

    func testFloat32RetainsNonHalfRepresentableInputAcrossAdapters() async throws {
        let renderer = try LumeraRenderer(precision:.float32), style = try renderer.prepare(Profile.standard)
        let gray: Float = 0.7502
        let data = [gray,gray,gray,1].withUnsafeBytes { Data($0) }
        let input = CIImage(bitmapData:data,bytesPerRow:16,size:.init(width:1,height:1),format:.RGBAf,colorSpace:space)
        let full = try await renderer.render(input,style:style)
        let tile = try await renderer.renderTiled(input,style:style)
        let roi = try await renderer.renderRegion(input,region:input.extent,style:style)
        for result in [full,tile,roi] {
            XCTAssertEqual(values(result,result.extent,context:renderer.context)[0],gray,accuracy:1e-5)
            XCTAssertEqual(result.properties[kCGImagePropertyDepth as String] as? Int,32)
        }
    }

    func testPanoramaLargeGlowUsesFullFrameScale() async throws {
        let renderer = try LumeraRenderer(), image = CIImage(color:.white).cropped(to:CGRect(x:0,y:0,width:9000,height:8))
        var profile = Profile.standard
        profile.parameters.glow.enabled = true; profile.parameters.glow.amount = 0.7; profile.parameters.glow.farSigma = 64
        let rect = CGRect(x:4700,y:2,width:7,height:3)
        let output = try await renderer.renderRegion(image,region:rect,style:renderer.prepare(profile))
        for channel in values(output,output.extent,context:renderer.context) { XCTAssertEqual(channel,1,accuracy:0.002) }
    }

    func testOddLargeGridROIAndProcessingRatios() async throws {
        let input = source(width:1921,height:1081)
        let region = CGRect(x:1283,y:641,width:97,height:83)
        var profile = Profile.standard
        profile.parameters.softening.enabled=true; profile.parameters.softening.amount=1
        profile.parameters.glow.enabled=true; profile.parameters.glow.amount=1
        profile.parameters.halation.enabled=true; profile.parameters.halation.amount=0.8
        for precision in [RenderingPrecision.float32,.float16] {
            let renderer = try LumeraRenderer(precision:precision), prepared = try renderer.prepare(profile)
            for resolution in EffectResolution.allCases {
                var options = RenderOptions(maximumLongEdge:1733)
                options.glowScale=resolution; options.halationScale=resolution; options.softeningScale=resolution
                let full = try await renderer.render(input,style:prepared,options:options)
                let part = try await renderer.renderRegion(input,region:region,style:prepared,options:options)
                let a = values(full,region,context:renderer.context), b = values(part,part.extent,context:renderer.context)
                let error = zip(a,b).map { abs($0-$1) }.max()!
                XCTAssertLessThanOrEqual(error,precision == .float32 ? 1e-4 : 2e-3,"divisor=\(resolution.rawValue), precision=\(precision)")
            }
        }
    }

    func testTiledOutputCanExceedSingleMetalTextureWidth() async throws {
        let renderer = try LumeraRenderer()
        let width = TextureDimensions.maximumEdge(device:renderer.device)+1
        let bounds = CGRect(x:0,y:0,width:width,height:7)
        let image = CIImage(color:.white).cropped(to:bounds)
        var profile = Profile.standard
        profile.parameters.vignette.enabled=true; profile.parameters.vignette.amountEV=2
        let out = try await renderer.renderTiled(image,style:renderer.prepare(profile),workingMemoryLimit:4*1024*1024)
        XCTAssertEqual(out.extent,bounds)
        let center = values(out,CGRect(x:width/2,y:3,width:1,height:1),context:renderer.context)[0]
        let corner = values(out,CGRect(x:width-1,y:3,width:1,height:1),context:renderer.context)[0]
        XCTAssertGreaterThan(center,corner+0.1)
    }

    func testBudgetAndRegionRejected() async throws {
        let renderer = try LumeraRenderer(), style = try renderer.prepare(Profile.standard)
        let image = source(width:1,height:7)
        do { _ = try await renderer.renderTiled(image,style:style,workingMemoryLimit:1); XCTFail("impossible budget") } catch {}
        do { _ = try await renderer.renderRegion(image,region:CGRect(x:0,y:0,width:0.5,height:7),style:style); XCTFail("fractional ROI") } catch {}
        let result = try await renderer.renderTiled(image,style:style)
        let full = try await renderer.render(image,style:style)
        XCTAssertEqual(values(result,result.extent,context:renderer.context),values(full,image.extent,context:renderer.context))
    }
}
