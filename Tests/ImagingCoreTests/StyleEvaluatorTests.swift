import XCTest
@testable import ImagingCore

final class ResponseCurveTests:XCTestCase {
    func testLogAxesClampingAndMissingInput() throws {
        let curve=ResponseCurve(knots:[.init(x:100,y:1),.init(x:400,y:3)])
        XCTAssertEqual(try curve.value(at:200,axis:.iso),2,accuracy:1e-12)
        XCTAssertEqual(try curve.value(at:25,axis:.iso),1)
        XCTAssertEqual(try curve.value(at:1600,axis:.iso),3)
        let seconds=ResponseCurve(knots:[.init(x:0.01,y:0),.init(x:0.04,y:2)])
        XCTAssertEqual(try seconds.value(at:0.02,axis:.exposureDurationSeconds),1,accuracy:1e-12)
        XCTAssertThrowsError(try curve.value(at:0,axis:.iso))
    }
    func testRejectsNumericallyCollapsedAndOverflowingAxes() throws {
        XCTAssertThrowsError(try ResponseCurve(knots:[.init(x:400,y:0),.init(x:400.nextUp,y:1)]).validate(axis:.iso))
        XCTAssertThrowsError(try ResponseCurve(knots:[.init(x: -Double.greatestFiniteMagnitude,y:0),.init(x:Double.greatestFiniteMagnitude,y:1)]).validate(axis:.exposureBiasEV))
    }
    func testRejectsInvalidNodesAndConditions() throws {
        for nodes:[ResponseKnot] in [[.init(x:0,y:1),.init(x:100,y:2)],[.init(x:100,y:1),.init(x:100,y:2)],[.init(x:400,y:1),.init(x:100,y:2)],[.init(x:100,y:.nan)]] {
            XCTAssertThrowsError(try ResponseCurve(knots:nodes).validate(axis:.iso))
        }
        var c=CaptureConditions();c.iso = -1;XCTAssertThrowsError(try c.validate())
        c=CaptureConditions();c.exposureDurationSeconds = .infinity;XCTAssertThrowsError(try c.validate())
    }
}
final class StyleEvaluatorTests:XCTestCase {
    private func profile() -> Profile {
        var p=Profile.standard;p.parameters.grain.enabled=true;p.parameters.grain.amount=0.01
        p.responses=[ConditionBinding(target:.grainAmount,axis:.iso,operation:.replace,curve:.init(knots:[.init(x:100,y:0.01),.init(x:400,y:0.03)]))]
        return p
    }
    func testConditionsApplyOnlyExplicitRulesThenUserAdjustments() throws {
        let p=profile(),definition=try StyleEvaluator.compile(p)
        var conditions=CaptureConditions();conditions.iso=200;conditions.exposureBiasEV = -1
        var adjustment=StyleAdjustments();adjustment.grainMultiplier=2;adjustment.exposureEV = -1
        let result=try StyleEvaluator.evaluate(definition,conditions:conditions,adjustments:adjustment)
        XCTAssertEqual(result.parameters.grain.amount,0.04,accuracy:1e-12)
        XCTAssertEqual(result.parameters.color.exposureEV,-1)
        XCTAssertEqual(try StyleEvaluator.evaluate(definition,conditions:conditions).parameters.color.exposureEV,0)
        let missing=try StyleEvaluator.evaluate(definition)
        XCTAssertEqual(missing.parameters.grain.amount,0.01)
        XCTAssertEqual(missing.diagnostics.first?.status,.missingCondition)
        XCTAssertEqual(p,profileIgnoringRandomID(p))
    }
    private func profileIgnoringRandomID(_ p:Profile)->Profile {var copy=profile();copy.id=p.id;return copy}
    func testDisabledEffectStaysDisabledAndEnabledZeroCanRespond() throws {
        var p=profile();p.parameters.grain.enabled=false
        var c=CaptureConditions();c.iso=400
        XCTAssertFalse(try StyleEvaluator.evaluate(StyleEvaluator.compile(p),conditions:c).parameters.grain.isActive)
        p.parameters.grain.enabled=true;p.parameters.grain.amount=0
        XCTAssertEqual(try StyleEvaluator.evaluate(StyleEvaluator.compile(p),conditions:c).parameters.grain.amount,0.03)
    }
    func testRejectsDuplicateTargetUnsupportedOperationAndOutOfRangeDefinition() throws {
        var p=profile();p.responses.append(p.responses[0]);XCTAssertThrowsError(try StyleEvaluator.compile(p))
        p=profile();p.responses[0].curve.knots[1].y=0.2;XCTAssertThrowsError(try StyleEvaluator.compile(p))
        p=profile();p.responses[0].target = .noiseGain;XCTAssertThrowsError(try StyleEvaluator.compile(p))
        let data=try JSON.encode(profile())
        XCTAssertThrowsError(try JSONDecoder().decode(Profile.self,from:Data(String(decoding:data,as:UTF8.self).replacingOccurrences(of:"grain.amount",with:"arbitrary.expression").utf8)))
    }
    func testSaveReloadRetainsResponsesAndTransientConditionsDoNotEnterProfile() throws {
        let p=profile(),data=try JSON.encode(p),copy=try JSONDecoder().decode(Profile.self,from:data)
        XCTAssertEqual(p,copy)
        var c=CaptureConditions();c.iso=800
        XCTAssertEqual(try StyleEvaluator.evaluate(StyleEvaluator.compile(p),conditions:c).parameters,try StyleEvaluator.evaluate(StyleEvaluator.compile(copy),conditions:c).parameters)
        XCTAssertEqual(data,try JSON.encode(p))
        var old=String(decoding:data,as:UTF8.self);old=old.replacingOccurrences(of:"\"schemaVersion\" : 7",with:"\"schemaVersion\" : 3")
        XCTAssertThrowsError(try JSONDecoder().decode(Profile.self,from:Data(old.utf8)))
    }
    func testUpperBoundPlateauRemainsValidAcrossContinuousISO() throws {
        var p=profile()
        p.responses[0].curve.knots=[.init(x:100,y:0.1),.init(x:400,y:0.1)]
        let definition=try StyleEvaluator.compile(p)
        for iso in [127.0]+(100...400).map(Double.init) {
            var c=CaptureConditions();c.iso=iso
            let result=try StyleEvaluator.evaluate(definition,conditions:c)
            XCTAssertEqual(result.parameters.grain.amount,0.1)
        }
    }
    func testNoRulesKeepsStaticParametersAndAdjustmentClampingIsReported() throws {
        var p=Profile.standard;p.parameters.noise.enabled=true;p.parameters.noise.curve = .init(knots:zip([0.0,0.18,0.5,0.85,1],[0.08,0.08,0.08,0.08,0.08]).map{.init(x:$0,y:$1)})
        let definition=try StyleEvaluator.compile(p)
        XCTAssertEqual(try StyleEvaluator.evaluate(definition).parameters,p.parameters)
        var a=StyleAdjustments();a.noiseMultiplier=2
        let result=try StyleEvaluator.evaluate(definition,adjustments:a)
        XCTAssertEqual([0.0,0.18,0.5,0.85,1].map{result.parameters.noise.effectiveSigma(at:$0)},[0.1,0.1,0.1,0.1,0.1]);XCTAssertTrue(result.adjustmentLimits.contains("noise.amplitude"))
    }
}
