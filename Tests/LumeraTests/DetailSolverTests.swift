import XCTest
import ImagingCore
@testable import ImageAnalysis
final class DetailSolverTests:XCTestCase {
    func testJointRecoveryAndHeldOutResponse() throws {
        let fixture=try DetailReferenceSamples.make(side:2048);defer{fixture.cleanup()}
        let p=try DetailSolver.solve(measurements:fixture.measurements,baseline:.standard,options:.init(model:.digital,modules:[.detail],baseline:.standard),resources:.init())
        XCTAssertEqual(p.profile.parameters.softening.amount,0.45,accuracy:0.04)
        XCTAssertEqual(p.profile.parameters.detail.fineGain,1.18,accuracy:0.08)
        XCTAssertTrue(p.validatedModules.contains(.detail));XCTAssertFalse(p.validationPassed)
    }
    func testMissingCurveAndAlreadySofterInputRefuse() throws {
        let fixture=try DetailReferenceSamples.make();defer{fixture.cleanup()}
        var missing=fixture.measurements;missing.frames[0].curves=[:]
        XCTAssertThrowsError(try DetailSolver.solve(measurements:missing,baseline:.standard,options:.init(model:.digital,modules:[.detail],baseline:.standard),resources:.init()))
        var impossible=fixture.measurements
        for i in impossible.frames.indices where impossible.frames[i].step.role == .target {impossible.frames[i].metrics["mtf50"]=0.5}
        XCTAssertThrowsError(try DetailSolver.solve(measurements:impossible,baseline:.standard,options:.init(model:.digital,modules:[.detail],baseline:.standard),resources:.init()))
    }
    func testDuplicatePixelsAndUnmeasuredActiveBaselineRefuse() throws {
        let f=try DetailReferenceSamples.make();defer{f.cleanup()}
        var duplicate=f.measurements;duplicate.frames[1].fileDigest=duplicate.frames[0].fileDigest;duplicate.frames[1].sourceURL=duplicate.frames[0].sourceURL
        XCTAssertThrowsError(try DetailSolver.solve(measurements:duplicate,baseline:.standard,options:.init(model:.digital,modules:[.detail],baseline:.standard),resources:.init()))
        var active=Profile.standard;active.parameters.glow.enabled=true;active.parameters.glow.amount=0.2
        XCTAssertThrowsError(try DetailSolver.solve(measurements:f.measurements,baseline:active,options:.init(model:.digital,modules:[.detail],baseline:active),resources:.init()))
    }
    func testIncompleteQualityAndMixedISORefuse() throws {
        let f=try DetailReferenceSamples.make();defer{f.cleanup()}
        var missing=f.measurements;missing.frames[0].patches=[]
        XCTAssertThrowsError(try DetailSolver.solve(measurements:missing,baseline:.standard,options:.init(model:.digital,modules:[.detail],baseline:.standard),resources:.init()))
        var mixed=f.measurements;mixed.frames[0].step.expectedISO=200;mixed.frames[0].actualConditions.iso=200
        XCTAssertThrowsError(try DetailSolver.solve(measurements:mixed,baseline:.standard,options:.init(model:.digital,modules:[.detail],baseline:.standard),resources:.init()))
    }
    func testMissingHighFrequenciesCannotSeparateCancellingParameters() throws {
        let f=try DetailReferenceSamples.make(side:2048,highFrequency:false);defer{f.cleanup()}
        XCTAssertThrowsError(try DetailSolver.solve(measurements:f.measurements,baseline:.standard,options:.init(model:.digital,modules:[.detail],baseline:.standard),resources:.init()))
    }
    func testPoorPrintCannotSupportRecovery() throws {
        let f=try DetailReferenceSamples.make(side:2048,printWidth:8);defer{f.cleanup()}
        XCTAssertThrowsError(try DetailSolver.solve(measurements:f.measurements,baseline:.standard,options:.init(model:.digital,modules:[.detail],baseline:.standard),resources:.init()))
    }
    func testAlternateResolutionAndJointParameters() throws {
        let f=try DetailReferenceSamples.make(side:2048,fineGain:0.9,softness:0.3);defer{f.cleanup()}
        let p=try DetailSolver.solve(measurements:f.measurements,baseline:.standard,options:.init(model:.digital,modules:[.detail],baseline:.standard),resources:.init())
        XCTAssertEqual(p.profile.parameters.detail.fineGain,0.9,accuracy:0.08)
        XCTAssertEqual(p.profile.parameters.softening.amount,0.3,accuracy:0.04)
    }
    func testKnownParametersMatchIndependentPixelReference() throws {
        let fixture=try DetailReferenceSamples.make();defer{fixture.cleanup()}
        let source=fixture.measurements.frames.first{$0.step.role == .input}!,target=fixture.measurements.frames.first{$0.step.role == .target}!
        let image=try ImageCodec.load(source.sourceURL!),renderer=try MetalRenderer();defer{renderer.releaseCaches()}
        var profile=Profile.standard;profile.parameters.detail.enabled=true;profile.parameters.detail.fineGain=1.18
        profile.parameters.softening.enabled=true;profile.parameters.softening.amount=0.45
        let rendered=try renderer.render(image,style:ResolvedStyle(profile:profile),request:.init(input:image.descriptor)).image
        let targetPixels=try ImageCodec.load(target.sourceURL!)
        XCTAssertLessThan(zip(rendered.pixels,targetPixels.pixels).map{abs($0-$1)}.max()!,0.0001)
        let canonical=try renderer.prepareReferenceImage(rendered)
        let result=try renderer.measureFeatureStatistics(canonical,region:GenerationImages.region("edge",frame:source),kind:.edge)
        let rms=sqrt(zip(result.curves["edge"]!,target.curves["edge"]!).reduce(0){$0+pow($1.0-$1.1,2)}/128)
        XCTAssertLessThan(rms,0.0001)
        let texture=try renderer.renderFeatureStatistics(image,style:ResolvedStyle(profile:profile),request:.init(input:image.descriptor),region:GenerationImages.region("detail",frame:source),kind:.texture)
        XCTAssertEqual(texture.metrics["rms"]!,target.metrics["detailRMS"]!,accuracy:0.0001)
    }

}
