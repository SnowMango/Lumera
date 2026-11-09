import XCTest
import Metal
import ImagingCore
@testable import ImageRendering

final class ReferenceRenderSessionTests:XCTestCase {
    func testFailedConsumerDoesNotPublishPrefix() throws {
        let device=try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let session=try ReferenceRenderSession(device:device,cacheLimitBytes:1024*1024)
        let pixels=Array(repeating:Float(0.5),count:8*8*4).enumerated().map{$0.offset%4==3 ? Float(1):$0.element}
        let request=RenderRequest(input:InputDescriptor(width:8,height:8))
        var profile=Profile.standard;profile.parameters.color.exposureEV=0.2
        let style=try ResolvedStyle(profile:profile)
        XCTAssertThrowsError(try session.withRenderedTexture(pixels:pixels,style:style,correction:nil,resources:.init(),request:request){_,_ in ()})
        XCTAssertEqual(session.cachedBytes,0)
        let values=try session.withRenderedTexture(pixels:pixels,style:style,correction:nil,resources:.init(),request:request){texture,command in
            command.commit();command.waitUntilCompleted();XCTAssertNil(command.error)
            return RenderHarness.read(texture)
        }
        XCTAssertEqual(values.count,pixels.count)
        XCTAssertEqual(session.lastWork.uploads,1)
        session.releaseCaches();XCTAssertEqual(session.cachedBytes,0)
    }
}
