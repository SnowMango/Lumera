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
