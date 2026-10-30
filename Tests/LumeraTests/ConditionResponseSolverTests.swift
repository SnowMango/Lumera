import XCTest
import ImagingCore
@testable import ImageAnalysis
final class ConditionResponseSolverTests:XCTestCase {
    func testIndependentMiddleISOImageValidation() throws {
        let results=try ConditionDeveloperCheck.run()
        XCTAssertLessThanOrEqual(try XCTUnwrap(results["heldOutCondition"]),0.10)
        XCTAssertEqual(results["rejectUnsupportedAxis"],0)
    }
    private func captures()throws->CaptureSet {
        let plan=try CaptureProtocol(input:.init(id:"input",isoLevels:[100,400,1600],baseExposureSeconds:0.01),target:.init(id:"target",isoLevels:[200,800,3200],baseExposureSeconds:0.02))
        return .init(protocolVersion:plan.version,records:plan.steps.map{s in
            var c=CaptureConditions();c.iso=s.expectedISO;c.exposureDurationSeconds=s.expectedExposureSeconds
            return .init(url:URL(fileURLWithPath:"/fixture/"+s.id+".png"),fileDigest:s.id,step:s,actualConditions:c,issues:[])
        },issues:[])
    }
    private func proposals()->[GenerationProposal] {
        zip([100.0,1600],[0.01,0.02]).map{iso,sigma in
            var p=Profile.standard;p.parameters.noise.enabled=true;p.parameters.noise.curve = .init(function:.init(family:.constant,start:sigma,end:sigma))
            let limit=GenerationLimits.cases(for:.texture).first{$0.caseID=="variance"}!
            return .init(profile:p,evidence:[.init(algorithm:.texture,caseID:"independent",status:.passed,measured:0,limit:limit,detail:"independent reference")],unresolved:[],resourceDigests:[:],validatedModules:[.texture],sourceISO:iso)
        }
    }
    func testUsesInputISOAndLeavesMiddleValidationPending() throws {
        let p=try ConditionResponseSolver.solve(proposals:proposals(),captures:captures(),baseline:.standard)
        let definition=try StyleEvaluator.compile(p.profile)
        for (iso,sigma) in [(100.0,0.01),(400.0,0.015),(1600.0,0.02)] {
            var c=CaptureConditions();c.iso=iso
            XCTAssertEqual(try StyleEvaluator.evaluate(definition,conditions:c).parameters.noise.effectiveSigma(at:0.5),sigma,accuracy:1e-8)
        }
        XCTAssertFalse(p.validationPassed)
        XCTAssertFalse(p.validatedModules.contains(.conditionResponse))
        XCTAssertTrue(p.unresolved.contains{$0.contains("中间")})
        XCTAssertTrue(p.unresolved.contains{$0.contains("快门")})
    }
    func testMissingMiddleDuplicateAxisOrUnqualifiedProposalRefuse() throws {
        var noMiddle=try captures();noMiddle.records.removeAll{$0.step.conditionIndex==1}
        XCTAssertThrowsError(try ConditionResponseSolver.solve(proposals:proposals(),captures:noMiddle,baseline:.standard))
        var repeated=proposals();repeated[1].sourceISO=100
        XCTAssertThrowsError(try ConditionResponseSolver.solve(proposals:repeated,captures:captures(),baseline:.standard))
        var unqualified=proposals();unqualified[1].validatedModules=[]
        XCTAssertThrowsError(try ConditionResponseSolver.solve(proposals:unqualified,captures:captures(),baseline:.standard))
    }
    func testChangingUnrepresentedColorOrNoiseShapeRefuses() throws {
        var changed=proposals();changed[1].profile.parameters.color.exposureEV=0.5
        XCTAssertThrowsError(try ConditionResponseSolver.solve(proposals:changed,captures:captures(),baseline:.standard))
        changed=proposals();changed[1].profile.parameters.noise.curve = .init(function:.init(family:.linear,start:0.04,end:0.005))
        XCTAssertThrowsError(try ConditionResponseSolver.solve(proposals:changed,captures:captures(),baseline:.standard))
    }
}
