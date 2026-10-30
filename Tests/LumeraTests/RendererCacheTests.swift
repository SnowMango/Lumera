import XCTest
import ImagingCore
import ImageRendering
@testable import ImageAnalysis
final class RendererCacheTests:XCTestCase {
    func testAllValidParameterChangesMatchFreshRenderer() throws {
        let renderer=try MetalRenderer(),fresh=try MetalRenderer(),image=try Fixtures.make(.texture,width:97,height:65)
        var p=try StylePresets.make("film-demo")
        p.parameters.detail.enabled=true;p.parameters.noise.enabled=true;p.parameters.noise.curve = .init(knots:zip([0.0,0.18,0.5,0.85,1],[0.01,0.01,0.01,0.01,0.01]).map{.init(x:$0,y:$1)})
        let request=RenderRequest(input:image.descriptor)
        _=try renderer.render(image,style:ResolvedStyle(profile:p),request:request)
        for parameter in ParameterDescriptor.all {
            var changed=p
            let v=changed.parameters[keyPath:parameter.keyPath]
            changed.parameters[keyPath:parameter.keyPath]=min(parameter.range.upperBound,v+(parameter.range.upperBound-parameter.range.lowerBound)*0.01)
            try changed.validate()
            let style=try ResolvedStyle(profile:changed)
            let actual=try renderer.render(image,style:style,request:request)
            fresh.releaseCaches()
            let expected=try fresh.render(image,style:style,request:request)
            XCTAssertEqual(actual.image.pixels,expected.image.pixels,parameter.id)
        }
    }
    func testPreviewCacheMutationDimensionsCancellationAndRelease() async throws {
        let renderer=try MetalRenderer(),fresh=try MetalRenderer(),p=try StylePresets.make("digital-demo"),style=try ResolvedStyle(profile:p)
        let source=try Fixtures.make(.patches,width:3000,height:120)
        var changed=source;changed.pixels[0]=0.2
        for image in [source,changed,source,try ImageFrame(width:120,height:3000,pixels:source.pixels)] {
            for limit:Int? in [1280,300,nil,1280] {
                let request=RenderRequest(input:image.descriptor,maximumLongEdge:limit)
                let actual=try renderer.render(image,style:style,request:request)
                fresh.releaseCaches();let expected=try fresh.render(image,style:style,request:request)
                XCTAssertEqual(actual.image.pixels,expected.image.pixels)
                if limit==1280 {XCTAssertLessThanOrEqual(renderer.cachedBytes,1280*52*16*3)}
                renderer.releaseCaches();XCTAssertEqual(renderer.cachedBytes,0)
            }
        }
        let task=Task{withUnsafeCurrentTask{$0?.cancel()};return try renderer.render(source,style:style,request:RenderRequest(input:source.descriptor))}
        do{_=try await task.value;XCTFail("cancelled render succeeded")}catch is CancellationError{}
        _=try renderer.render(source,style:style,request:RenderRequest(input:source.descriptor,maximumLongEdge:1280))
    }
}
