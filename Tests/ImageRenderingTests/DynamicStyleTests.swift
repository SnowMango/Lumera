import XCTest
import Metal
import ImagingCore
@testable import ImageRendering

final class DynamicStyleTests:XCTestCase {
    private func finish(_ command:MTLCommandBuffer) {
        let done=DispatchSemaphore(value:0);command.addCompletedHandler{_ in done.signal()}
        command.commit();done.wait();XCTAssertNil(command.error)
    }
    func testContinuousConditionsReuseStaticLUTAndMatchDirectRender() throws {
        let h=try RenderHarness(),input=try h.texture(width:192,height:128,point:true)
        var p=Profile.standard
        let lut=LUTAsset(name:"identity",cubeText:"LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n")
        p.parameters.softening.enabled=true;p.parameters.softening.amount=0.5
        p.parameters.grain.enabled=true;p.parameters.grain.amount=0.02
        p.parameters.noise.enabled=true;p.parameters.noise.curve = .init(knots:zip([0.0,0.18,0.5,0.85,1],Array(repeating:0.01,count:5)).map{.init(x:$0,y:$1)})
        p.temporalPolicy.noise = .evolving
        p.responses=[.init(target:.softeningSigma,axis:.iso,operation:.replace,curve:.init(knots:[.init(x:100,y:0.5),.init(x:6400,y:8)])),.init(target:.grainSize,axis:.iso,operation:.replace,curve:.init(knots:[.init(x:100,y:0.5),.init(x:6400,y:8)]))]
        let definition=try StyleEvaluator.compile(p),prepared=try h.encoder.prepare(definition,lut:lut)
        var request=RenderRequest(input:InputDescriptor(width:192,height:128))
        var first=[Float](),last=[Float]()
        for i in 0..<300 {
            var c=CaptureConditions();c.iso=100*pow(64,Double(i)/299);request.frameIndex=UInt32(i)
            let values=try StyleEvaluator.evaluate(definition,conditions:c)
            let command=try XCTUnwrap(h.queue.makeCommandBuffer())
            let output=try h.encoder.encode(input,style:prepared,parameters:FrameStyleParameters(values),request:request,commandBuffer:command)
            finish(command)
            if i==0 {first=RenderHarness.read(output)}
            if i==299 {
                last=RenderHarness.read(output)
                let other=try RenderHarness()
                let direct=try other.encode(other.texture(width:192,height:128,point:true),other.encoder.prepare(values.resolvedStyle()),request)
                XCTAssertEqual(last,RenderHarness.read(direct))
            }
            XCTAssertLessThanOrEqual(h.encoder.cacheStatistics.kernelCount,64)
            XCTAssertLessThanOrEqual(h.encoder.cachedTextureBytes,256*1024*1024)
        }
        XCTAssertNotEqual(first,last)
        XCTAssertEqual(h.encoder.staticResourceStatistics.lutParses,1)
        XCTAssertEqual(h.encoder.staticResourceStatistics.lutUploads,1)
        print("Dynamic 300 frames: LUT parses/uploads=\(h.encoder.staticResourceStatistics), cache=\(h.encoder.cacheStatistics)")
        h.encoder.releaseCaches();XCTAssertEqual(h.encoder.cachedTextureBytes,0);XCTAssertEqual(h.encoder.cacheStatistics.kernelCount,0)
        var c=CaptureConditions();c.iso=6400
        let command=try XCTUnwrap(h.queue.makeCommandBuffer())
        let replay=try h.encoder.encode(input,style:prepared,parameters:FrameStyleParameters(StyleEvaluator.evaluate(definition,conditions:c)),request:request,commandBuffer:command)
        finish(command);XCTAssertEqual(last,RenderHarness.read(replay))
        var wrong=p;wrong.parameters.vignette.amountEV=1
        let wrongValues=try StyleEvaluator.evaluate(StyleEvaluator.compile(wrong))
        XCTAssertThrowsError(try h.encoder.encode(input,style:prepared,parameters:FrameStyleParameters(wrongValues),request:request,commandBuffer:XCTUnwrap(h.queue.makeCommandBuffer())))
    }
    func testZeroToNonzeroDoesNotNeedStaticPreparation() throws {
        let h=try RenderHarness(),input=try h.texture(width:64,height:48)
        var p=Profile.standard;p.parameters.vignette.enabled=true
        p.responses=[.init(target:.vignetteAmount,axis:.iso,operation:.replace,curve:.init(knots:[.init(x:100,y:0),.init(x:400,y:1)]))]
        let definition=try StyleEvaluator.compile(p),style=try h.encoder.prepare(definition)
        func render(_ iso:Double) throws -> [Float] {
            var c=CaptureConditions();c.iso=iso
            let cmd=try XCTUnwrap(h.queue.makeCommandBuffer())
            let output=try h.encoder.encode(input,style:style,parameters:FrameStyleParameters(StyleEvaluator.evaluate(definition,conditions:c)),request:RenderRequest(input:InputDescriptor(width:64,height:48)),commandBuffer:cmd)
            finish(cmd);return RenderHarness.read(output)
        }
        XCTAssertEqual(try render(100),RenderHarness.read(input));XCTAssertLessThan(try render(400)[0],0.5)
    }
}
final class NoiseTemporalTests:XCTestCase {
    func testEachNoiseTypeHasIndependentFixedAndEvolvingPolicy() throws {
        let h=try RenderHarness()
        for grain in [false,true] {
            var p=Profile.standard
            if grain {p.parameters.grain.enabled=true;p.parameters.grain.amount=0.03}
            else {p.parameters.noise.enabled=true;p.parameters.noise.curve = .init(knots:zip([0.0,0.18,0.5,0.85,1],Array(repeating:0.03,count:5)).map{.init(x:$0,y:$1)})}
            for mode in TemporalMode.allCases {
                p.temporalPolicy.noise=mode;p.temporalPolicy.grain=mode
                let a=try h.render(p,width:96,height:64,frame:0),b=try h.render(p,width:96,height:64,frame:1)
                XCTAssertEqual(a,try h.render(p,width:96,height:64,frame:0))
                if mode == .fixed {XCTAssertEqual(a,b)} else {XCTAssertNotEqual(a,b)}
                XCTAssertNotEqual(a,try h.render(p,width:96,height:64,seed:43))
            }
        }
    }
}
