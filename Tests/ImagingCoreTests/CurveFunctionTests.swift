import XCTest
@testable import ImagingCore
final class CurveFunctionTests:XCTestCase {
    func testAnalyticFamiliesAndRoundTrip() throws {
        for family in CurveFamily.allCases {
            let f=CurveFunction(family:family)
            let c=ResponseCurve(function:f)
            try c.validate(kind:.grain)
            XCTAssertEqual(try JSONDecoder().decode(ResponseCurve.self,from:JSON.encode(c)),c)
            for i in 0...100 {let y=c.value(at:Double(i)/100);XCTAssertTrue(y.isFinite && (0...1).contains(y))}
        }
        var f=CurveFunction(family:.power);f.exponent=2
        XCTAssertEqual(ResponseCurve(function:f).value(at:0.5),0.25,accuracy:1e-12)
        f=CurveFunction(family:.bell);f.center=0.5
        XCTAssertEqual(ResponseCurve(function:f).value(at:0.5),1,accuracy:1e-12)
    }
    func testLogConditionFunctionAndToneRestrictions() throws {
        var f=CurveFunction(family:.linear);f.xLower=100;f.xUpper=400;f.start=1;f.end=3
        let c=ResponseCurve(function:f)
        XCTAssertEqual(try c.value(at:200,axis:.iso),2,accuracy:1e-12)
        XCTAssertThrowsError(try ResponseCurve(function:.init(family:.bell)).validate(kind:.tone))
        f.xUpper=100
        XCTAssertThrowsError(try ResponseCurve(function:f).validate(axis:.iso))
    }
    func testSmoothNodesDoNotOvershootAtTurningPoints() throws {
        let c=ResponseCurve(knots:[.init(x:0,y:0),.init(x:0.3,y:1),.init(x:0.6,y:0.2),.init(x:1,y:0.7)],interpolation:.smooth)
        for i in 0...1000 {XCTAssertTrue((0...1).contains(c.value(at:Double(i)/1000)))}
        XCTAssertEqual(c.value(at:0.3),1,accuracy:1e-12)
    }
    func testAnalyticPlateauRemainsValidAcrossISO() throws {
        var f=CurveFunction(family:.linear,start:0.1,end:0.1);f.xLower=100;f.xUpper=400
        var p=Profile();p.responses=[.init(target:.grainAmount,axis:.iso,operation:.replace,curve:.init(function:f))]
        let definition=try StyleEvaluator.compile(p)
        for iso in 100...400 {var c=CaptureConditions();c.iso=Double(iso);XCTAssertEqual(try StyleEvaluator.evaluate(definition,conditions:c).parameters.grain.amount,0.1)}
    }
    func testNoiseAdjustmentScalesFunctionBeforeSaturation() throws {
        var p=Profile();p.parameters.noise.enabled=true
        p.parameters.noise.curve = .init(function:.init(family:.linear,start:0,end:0.1))
        var a=StyleAdjustments();a.noiseMultiplier=2
        let result=try StyleEvaluator.evaluate(StyleEvaluator.compile(p),adjustments:a)
        XCTAssertEqual(result.parameters.noise.effectiveSigma(at:0.25),0.05,accuracy:1e-12)
        XCTAssertEqual(result.parameters.noise.effectiveSigma(at:0.75),0.1,accuracy:1e-12)
    }
    func testResponseUpperEndpointDoesNotOvershootDueToRoundoff() throws {
        var p=Profile();p.parameters.grain.amount=0.023
        let upper=ResponseTarget.grainAmount.responseRange(operation:.multiply,parameters:p.parameters).upperBound
        p.responses=[.init(target:.grainAmount,axis:.iso,operation:.multiply,curve:.init(knots:[.init(x:100,y:upper),.init(x:400,y:upper)]))]
        try p.validate()
    }
    func testNewProfileStoresOnlyNewCurveModel() throws {
        var p=Profile();p.parameters.noise.curve=ResponseCurve(function:.init(family:.bell,start:0,end:0.03))
        let data=try JSON.encode(p),text=String(decoding:data,as:UTF8.self)
        XCTAssertEqual(p.schemaVersion,7)
        XCTAssertFalse(text.contains("\"sigmas\""));XCTAssertFalse(text.contains("\"nodes\""))
        XCTAssertEqual(try JSONDecoder().decode(Profile.self,from:data),p)
    }
}
