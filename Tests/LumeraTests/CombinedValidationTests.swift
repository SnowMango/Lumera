import XCTest
import ImagingCore
@testable import ImageAnalysis
final class CombinedValidationTests:XCTestCase {
    func testRGBCombinedValidationRejectsRegressionAndDoesNotReusePassFlag()throws {
        let f=try GlowDeveloperCheck.fixture();defer{f.cleanup()}
        var p=try GlowSolver.solve(measurements:f.bundle,baseline:f.baseline,options:.init(model:.film,modules:[.glow],baseline:f.baseline),resources:.init())
        let good=try CombinedValidation.run(proposal:p,baseline:f.baseline,measurements:f.bundle,resources:.init())
        XCTAssertTrue(good.passed);XCTAssertFalse(good.rows.isEmpty)
        p.profile.parameters.color.exposureEV=0.5;p.validationPassed=true
        let bad=try CombinedValidation.run(proposal:p,baseline:f.baseline,measurements:f.bundle,resources:.init())
        XCTAssertFalse(bad.passed)
        XCTAssertTrue(bad.rows.contains{$0.status == .failed})
    }
    func testIndependentColorAndDetailBranches() throws {
        let results=try CombinedDeveloperCheck.run()
        XCTAssertEqual(results["perModuleRegression"],0)
    }
    func testISOEndpointCoverageCannotUseGroupNames() throws {
        let records=try ConditionDeveloperCheck.captures().records.filter{$0.step.target == .composite}
        var frames=records.map{FrameMeasurements(fileDigest:$0.fileDigest,step:$0.step,actualConditions:$0.actualConditions,width:2048,height:2048,patches:[],pose:nil)}
        let response=ConditionBinding(target:.noiseGain,axis:.iso,operation:.multiply,curve:.init(knots:[.init(x:100,y:0.5),.init(x:1600,y:1)]))
        XCTAssertNoThrow(try CombinedValidation.validateConditions(frames,responses:[response]))
        var wrong=response;wrong.curve = .init(knots:[.init(x:100,y:0.5),.init(x:3200,y:1)])
        XCTAssertThrowsError(try CombinedValidation.validateConditions(frames,responses:[wrong]))
        for i in frames.indices {frames[i].actualConditions.iso=100;frames[i].step.expectedISO=100}
        XCTAssertThrowsError(try CombinedValidation.validateConditions(frames,responses:[response]))
    }
    func testMissingProofAndChangedResourcesRefuse()throws {
        let p=GenerationProposal(profile:.standard,evidence:[],unresolved:[],resourceDigests:[:])
        XCTAssertThrowsError(try CombinedValidation.run(proposal:p,baseline:.standard,measurements:.init(frames:[],resourceDigests:[:]),resources:.init()))
    }
}
