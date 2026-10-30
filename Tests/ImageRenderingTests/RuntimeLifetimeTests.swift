import XCTest
import Metal
import ImagingCore
import ImageRendering
final class RuntimeLifetimeTests:XCTestCase {
    func testRejectsUnretainedAndEnqueuedCommands() throws {
        let h=try RenderHarness(),source=try h.texture(width:64,height:48),style=try h.encoder.prepare(ResolvedStyle(profile:.standard)),request=RenderRequest(input:InputDescriptor(width:64,height:48))
        let unretained=try XCTUnwrap(h.queue.makeCommandBufferWithUnretainedReferences())
        XCTAssertThrowsError(try h.encoder.encode(source,style:style,request:request,commandBuffer:unretained))
        let enqueued=try XCTUnwrap(h.queue.makeCommandBuffer());enqueued.enqueue()
        XCTAssertThrowsError(try h.encoder.encode(source,style:style,request:request,commandBuffer:enqueued))
        enqueued.commit();enqueued.waitUntilCompleted()
    }
    func testTwoInFlightArenasKeepIndependentPixels() throws {
        let h=try RenderHarness(),profile=try StylePresets.make("film-demo"),style=try h.encoder.prepare(ResolvedStyle(profile:profile))
        let request=RenderRequest(input:InputDescriptor(width:128,height:96))
        let a=try h.texture(width:128,height:96,value:0.2),b=try h.texture(width:128,height:96,value:0.7)
        let ca=try XCTUnwrap(h.queue.makeCommandBuffer()),cb=try XCTUnwrap(h.queue.makeCommandBuffer())
        let oa=try h.encoder.encode(a,style:style,request:request,commandBuffer:ca)
        let ob=try h.encoder.encode(b,style:style,request:request,commandBuffer:cb)
        XCTAssertFalse(oa === ob)
        let done=DispatchGroup();done.enter();done.enter()
        ca.addCompletedHandler{_ in done.leave()};cb.addCompletedHandler{_ in done.leave()}
        ca.commit();cb.commit();done.wait()
        XCTAssertNil(ca.error);XCTAssertNil(cb.error)
        XCTAssertEqual(RenderHarness.read(oa),try RenderHarness().render(profile,width:128,height:96,value:0.2))
        XCTAssertEqual(RenderHarness.read(ob),try RenderHarness().render(profile,width:128,height:96,value:0.7))
        XCTAssertLessThanOrEqual(h.encoder.cachedTextureBytes,256*1024*1024)
        h.encoder.releaseCaches();XCTAssertEqual(h.encoder.cachedTextureBytes,0)
    }
}
