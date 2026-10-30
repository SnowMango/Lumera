import XCTest
import ImagingCore
@testable import ImageAnalysis
final class StyleAcceptanceTests:XCTestCase {
    func testNarrowestSupportedToneAgainstDenseDoubleReference() throws {
        let knots:[ResponseKnot]=[.init(x:0,y:0),.init(x:0.50000002,y:0),.init(x:0.50100003,y:1),.init(x:1,y:1)]
        var p=Profile.standard;p.parameters.tone.enabled=true;p.parameters.tone.curve = .init(knots:knots,interpolation:.smooth)
        var input=try ImageFrame.solid(width:1024,height:8,value:0)
        for y in 0..<8 {for x in 0..<1024 {let v=Float(0.4999+Double(x)/1023*0.0013);for c in 0..<3{input.pixels[(y*1024+x)*4+c]=v}}}
        let out=try MetalRenderer().render(input,style:ResolvedStyle(profile:p),request:RenderRequest(input:input.descriptor)).image
        for x in 0..<1024 {
            let expected=AcceptanceReference.monotone(Double(input.pixels[x*4]),knots:knots.map{($0.x,$0.y)})
            XCTAssertEqual(Double(out.pixels[x*4]),expected,accuracy:0.0002)
        }
    }
    func testPerEffectPerConditionAndScaleReport() throws {
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("TestMaterials/Lumera-v1")
        var p=try StylePresets.make("film-demo")
        p.parameters.noise.enabled=true;p.parameters.noise.curve = .init(knots:zip([0.0,0.18,0.5,0.85,1],[0.02,0.015,0.01,0.005,0.002]).map{.init(x:$0,y:$1)})
        p.parameters.detail.enabled=true;p.parameters.detail.fineGain=0.8;p.parameters.detail.sharpenAmount=0.1
        p.responses=[.init(target:.grainAmount,axis:.iso,operation:.replace,curve:.init(knots:[.init(x:100,y:0.01),.init(x:400,y:0.03)]))]
        var iso400=CaptureConditions();iso400.iso=400
        let report=try StyleAcceptance.run(profile:p,conditions:[CaptureConditions(),iso400],fixtures:root)
        XCTAssertEqual(Set(report.results.map(\.longEdge)),[720,1280,2048])
        XCTAssertEqual(Set(report.results.map(\.conditionIndex)),[0,1])
        XCTAssertFalse(report.results.contains{$0.status == .failed},report.results.filter{$0.status == .failed}.description)
        XCTAssertTrue(report.results.contains{$0.effect=="tone" && $0.status == .passed})
        XCTAssertTrue(report.results.contains{$0.effect=="grain"})
        XCTAssertEqual(report.evaluations[0].first?.status,.missingCondition)
        XCTAssertEqual(report.evaluations[1].first?.status,.applied)
        let data=try JSON.encode(report);XCTAssertGreaterThan(data.count,1000)
        if let path=ProcessInfo.processInfo.environment["LUMERA_ACCEPTANCE_REPORT"] {try data.write(to:URL(fileURLWithPath:path))}
    }
}
