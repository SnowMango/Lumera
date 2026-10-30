import XCTest
import ImagingCore
@testable import ImageRendering
final class AnalyticCurveRenderingTests:XCTestCase {
    func testEveryFunctionMatchesCPUThroughGPUPaths() throws {
        let h=try RenderHarness(precision:.float32)
        for family in CurveFamily.allCases {
            for input:Float in [0,0.03,0.25,0.5,0.83,1] {
                var f=CurveFunction(family:family,start:0.1,end:0.9);f.exponent=3;f.center=0.3;f.width=0.12
                let c=ResponseCurve(function:f)
                if family != .bell {
                    var p=Profile();p.parameters.tone.enabled=true;p.parameters.tone.curve=c
                    let out=try h.render(p,width:4,height:4,value:input)
                    XCTAssertEqual(Double(out[0]),c.value(at:Double(input)),accuracy:0.0002,"\(family) at \(input)")
                }
                // Same random field and seed: compare analytic noise amplitude with an independently fixed amplitude.
                var p=Profile();p.parameters.noise.enabled=true;p.parameters.noise.lumaSigma=0;p.parameters.noise.chromaRatio=0
                f.start=0.003;f.end=0.015;p.parameters.noise.curve = .init(function:f)
                let actual=try h.render(p,width:8,height:8,value:input)
                let sigma=p.parameters.noise.curve.value(at:Double(input))
                p.parameters.noise.curve = .init(function:.init(family:.constant,start:sigma,end:sigma))
                let expected=try h.render(p,width:8,height:8,value:input)
                XCTAssertLessThan(zip(actual,expected).map{abs($0-$1)}.max()!,0.0002)
            }
        }
    }
    func testSteepSmoothFamiliesStayInRangeAtEdges() throws {
        let h=try RenderHarness(precision:.float32)
        for family:CurveFamily in [.sigmoid,.threshold,.power] {
            for center in [0.0,1.0] {
                var f=CurveFunction(family:family);f.exponent=8;f.width=0.05;f.center=center
                var p=Profile();p.parameters.tone.enabled=true;p.parameters.tone.curve = .init(function:f)
                for input:Float in [0,0.001,0.5,0.999,1] {
                    let out=try h.render(p,width:4,height:4,value:input)
                    XCTAssertEqual(Double(out[0]),p.parameters.tone.curve.value(at:Double(input)),accuracy:0.0002)
                    XCTAssertTrue((0...1).contains(out[0]))
                }
            }
        }
    }
}
