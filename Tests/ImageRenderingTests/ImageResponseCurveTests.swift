import XCTest
import Metal
import ImagingCore
@testable import ImageRendering
final class ResponseCurveTests:XCTestCase {
    func testCurveValidationAndIdentity() throws {
        for knots:[ResponseKnot] in [[.init(x:0,y:0),.init(x:0,y:1)],[.init(x:0.1,y:0),.init(x:1,y:1)],[.init(x:0,y:1),.init(x:1,y:0)]] {
            XCTAssertThrowsError(try ResponseCurve(knots:knots).validate(kind:.tone))
        }
        let narrow=ResponseCurve(knots:[.init(x:0,y:0),.init(x:0.50000002,y:0),.init(x:0.50000014,y:1),.init(x:1,y:1)])
        for kind:ImageResponseKind in [.tone,.grain] {XCTAssertThrowsError(try narrow.validate(kind:kind))}
        var p=Profile.standard;p.parameters.tone.enabled=true;p.parameters.tone.curve = .init(knots:[.init(x:0,y:0),.init(x:0.13,y:0.13),.init(x:1,y:1)],interpolation:.smooth)
        let h=try RenderHarness(),source=try h.texture(width:64,height:64,point:true)
        XCTAssertTrue(try h.encode(source,h.encoder.prepare(ResolvedStyle(profile:p)),RenderRequest(input:InputDescriptor(width:64,height:64))) === source)
        p.parameters.noise.curve = .init(knots:[.init(x:0,y:-0.1),.init(x:1,y:0)])
        XCTAssertThrowsError(try p.validate())
    }
    func testNonuniformNoiseAndExplicitNodeInsertions() throws {
        var n=Noise();n.enabled=true;n.lumaSigma=0;n.chromaRatio=0
        n.curve = .init(knots:[.init(x:0,y:0),.init(x:0.2,y:0.04),.init(x:0.6,y:0),.init(x:1,y:0)])
        var p=Profile.standard;p.parameters.noise=n
        let h=try RenderHarness(),out=try h.render(p,width:256,height:256,value:0.2)
        let residual=stride(from:0,to:out.count,by:4).map{Double(out[$0])-0.2}
        let sigma=sqrt(residual.reduce(0){$0+$1*$1}/Double(residual.count))
        XCTAssertEqual(sigma,0.04,accuracy:0.001)
        p.parameters.noise.curve.knots.insert(.init(x:0.5,y:0.01),at:2)
        XCTAssertEqual(p.parameters.noise.curve.knots.map(\.x),[0,0.2,0.5,0.6,1])
        XCTAssertEqual(p.parameters.noise.curve.knots.map(\.y),[0,0.04,0.01,0,0])
        p.parameters.tone.curve = .init(knots:[.init(x:0,y:0),.init(x:0.5,y:0.2),.init(x:1,y:1)],interpolation:.smooth)
        XCTAssertEqual(p.parameters.tone.curve.value(at:0.25),0.085,accuracy:1e-10)
        p.parameters.tone.curve.knots.insert(.init(x:0.25,y:0.1),at:1)
        XCTAssertEqual(p.parameters.tone.curve.knots.count,4)
        p.parameters.tone.curve = .init(knots:[.init(x:0,y:0),.init(x:1e-12,y:0.5),.init(x:1,y:1)],interpolation:.smooth)
        XCTAssertThrowsError(try p.validate())
    }
    func testNonuniformToneMatchesKnownCubicAndPlateau() throws {
        let h=try RenderHarness();var p=Profile.standard;p.parameters.tone.enabled=true
        p.parameters.tone.curve = .init(knots:[.init(x:0,y:0),.init(x:0.5,y:0.2),.init(x:1,y:1)],interpolation:.smooth)
        XCTAssertEqual(try h.render(p,width:16,height:16,value:0.25)[0],0.085,accuracy:0.0003)
        p.parameters.tone.curve = .init(knots:[.init(x:0,y:0.1),.init(x:0.2,y:0.1),.init(x:0.8,y:0.9),.init(x:1,y:1)],interpolation:.smooth)
        XCTAssertEqual(try h.render(p,width:16,height:16,value:0.1)[0],0.1,accuracy:0.0003)
    }
    func testGrainEnvelopeCanKeepDarkTextureAndDisableBrightTexture() throws {
        let h=try RenderHarness();var p=Profile.standard;p.parameters.grain.enabled=true;p.parameters.grain.amount=0.02
        p.parameters.grain.luminanceCurve = .init(knots:[.init(x:0,y:1),.init(x:0.4,y:1),.init(x:0.6,y:0),.init(x:1,y:0)])
        let dark=try h.render(p,width:128,height:128,value:0.2),bright=try h.render(p,width:128,height:128,value:0.8)
        let d=stride(from:0,to:dark.count,by:4).map{dark[$0]}
        XCTAssertGreaterThan((d.max() ?? 0)-(d.min() ?? 0),0.03)
        let b=stride(from:0,to:bright.count,by:4).map{bright[$0]}
        XCTAssertEqual(b.max(),b.min());XCTAssertEqual(b[0],0.8,accuracy:0.001)
    }
}
