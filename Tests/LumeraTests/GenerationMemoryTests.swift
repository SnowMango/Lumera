import XCTest
import ImagingCore
@testable import ImageAnalysis
final class GenerationMemoryTests:XCTestCase {
    func testExplicitBudgetAlsoBoundsReusablePoolWithoutChangingPixels() throws {
        let small=try MetalRenderer(cacheLimitBytes:1_048_576),normal=try MetalRenderer()
        defer{small.releaseCaches();normal.releaseCaches()}
        let image=try ImageFrame.solid(width:512,height:512,value:0.4)
        var profile=Profile.standard;profile.parameters.softening.enabled=true;profile.parameters.softening.amount=0.3
        let style=try ResolvedStyle(profile:profile),request=RenderRequest(input:image.descriptor)
        let a=try small.render(image,style:style,request:request).image,b=try normal.render(image,style:style,request:request).image
        XCTAssertEqual(a.pixels,b.pixels)
        XCTAssertLessThanOrEqual(Int(small.memoryStatistics["cachedTextureBytes"]!)!,1_048_576)
        XCTAssertLessThanOrEqual(Int(small.memoryStatistics["pooledTextureBytes"]!)!,524_288)
        small.releaseCaches()
        XCTAssertEqual(small.memoryStatistics["cachedTextureBytes"],"0")
        XCTAssertEqual(small.memoryStatistics["pooledTextureBytes"],"0")
    }
}

extension GenerationMemoryTests {
    func testReferenceScratchRetentionMatchesPreMigrationBaseline() throws {
        let renderer=try MetalRenderer()
        let image=try ImageFrame.solid(width:1920,height:1080,value:0.5)
        _=try renderer.render(image,style:ResolvedStyle(profile:StylePresets.make("film-demo")),request:.init(input:image.descriptor))
        let memory=renderer.memoryStatistics
        let retained=try XCTUnwrap(Int(try XCTUnwrap(memory["cachedTextureBytes"]))) + XCTUnwrap(Int(try XCTUnwrap(memory["pooledTextureBytes"])))
        XCTAssertLessThanOrEqual(retained,1920*1080*16*7,"Migration must not retain an additional full-size scratch surface")
    }
}
