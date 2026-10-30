import XCTest
import ImagingCore
import ImageRendering
@testable import ImageAnalysis

final class ToneColorSolverTests:XCTestCase {
    func testRecoversCanonicalMatrixAndToneUsingUnseenColorsAndMiddleISO() throws {
        let sample=try ColorReferenceSamples.make()
        let proposal=try ToneColorSolver.solve(measurements:sample,baseline:.standard,options:.init(model:.digital,modules:[.toneColor],baseline:.standard),resources:.init())
        for (a,b) in zip(proposal.profile.parameters.color.matrix.values,ColorReferenceSamples.matrix) {XCTAssertEqual(a,b,accuracy:0.012)}
        XCTAssertEqual(proposal.profile.parameters.tone.curve.value(at:0.25),0.20,accuracy:0.006)
        XCTAssertEqual(proposal.profile.parameters.tone.curve.value(at:0.75),0.80,accuracy:0.006)
        XCTAssertTrue(proposal.validatedModules.contains(.toneColor))
        XCTAssertFalse(proposal.validationPassed)
        XCTAssertFalse(proposal.evidence.isEmpty)
        XCTAssertEqual(proposal.profile.parameters.color.exposureEV,0)
        XCTAssertEqual(proposal.profile.parameters.color.shift,ColorShift())
    }
    func testRejectsExposureMismatchRankDeficiencyClippingAndFixedLUTAmbiguity() throws {
        let good=try ColorReferenceSamples.make()
        func solve(_ b:MeasurementBundle,_ r:GenerationResources = .init()) throws ->GenerationProposal {
            try ToneColorSolver.solve(measurements:b,baseline:.standard,options:.init(model:.digital,modules:[.toneColor],baseline:.standard),resources:r)
        }
        var single=good;single.frames.removeAll{$0.step.exposureEV != 0}
        var grey=good;for i in grey.frames.indices {for j in grey.frames[i].patches.indices where grey.frames[i].patches[j].kind == .color {grey.frames[i].patches[j].mean=[0.4,0.4,0.4]}}
        var clip=good;clip.frames[0].patches[0].clippedFraction=0.2
        var noHeldOut=good;noHeldOut.frames.removeAll{$0.step.purpose == .validation}
        var duplicate=good;duplicate.frames.append(good.frames[0])
        for bad in [single,grey,clip,noHeldOut,duplicate,try ColorReferenceSamples.make(exposureGain:1.4)] {XCTAssertThrowsError(try solve(bad))}
        XCTAssertThrowsError(try solve(good,.init(rendering:.init(lut:IndependentLUTCheck.cube{$0}))))
    }
    func testValidationFailureDoesNotSelectNewParametersOrMutateBaseline() throws {
        let good=try ColorReferenceSamples.make(),baseline=Profile.standard
        var bad=good
        for i in bad.frames.indices where bad.frames[i].step.role == .target && bad.frames[i].step.conditionIndex == 1 {
            for j in bad.frames[i].patches.indices {bad.frames[i].patches[j].mean=bad.frames[i].patches[j].mean.map{min(0.95,$0+0.05)}}
        }
        XCTAssertThrowsError(try ToneColorSolver.solve(measurements:bad,baseline:baseline,options:.init(model:.digital,modules:[.toneColor],baseline:baseline),resources:.init()))
        XCTAssertEqual(baseline.parameters,StyleParameters())
    }
    func testNeutralAndSmallPerturbationsStayStable() throws {
        func solve(_ b:MeasurementBundle)throws->GenerationProposal {try ToneColorSolver.solve(measurements:b,baseline:.standard,options:.init(model:.digital,modules:[.toneColor],baseline:.standard),resources:.init())}
        let neutral=try solve(ColorReferenceSamples.make(neutral:true))
        for (a,b) in zip(neutral.profile.parameters.color.matrix.values,ColorMatrix3x3().values) {XCTAssertEqual(a,b,accuracy:1e-6)}
        var perturbed=try ColorReferenceSamples.make()
        for i in perturbed.frames.indices where perturbed.frames[i].step.role == .target {for j in perturbed.frames[i].patches.indices {for c in 0..<3 {perturbed.frames[i].patches[j].mean[c]+=Double((i+j+c)%3-1)*0.0001}}}
        let result=try solve(perturbed)
        for (a,b) in zip(result.profile.parameters.color.matrix.values,ColorReferenceSamples.matrix) {XCTAssertEqual(a,b,accuracy:0.012)}
    }

    func testPreservesFixedColorControlsAndRequiresCompleteSplit() throws {
        let good=try ColorReferenceSamples.make()
        func solve(_ b:MeasurementBundle,_ baseline:Profile = .standard)throws->GenerationProposal {try ToneColorSolver.solve(measurements:b,baseline:baseline,options:.init(model:.digital,modules:[.toneColor],baseline:baseline),resources:.init())}
        var fixed=Profile.standard;fixed.parameters.color.exposureEV=0.5
        XCTAssertThrowsError(try solve(good,fixed))
        fixed = .standard;fixed.parameters.color.shift.redGreen=0.1
        XCTAssertThrowsError(try solve(good,fixed))
        fixed = .standard;fixed.parameters.color.whiteBalance.destination = .init(x:0.35,y:0.35)
        XCTAssertThrowsError(try solve(good,fixed))
        var noHigh=good;noHigh.frames.removeAll{$0.step.conditionIndex==2}
        XCTAssertThrowsError(try solve(noHigh))
        var leaked=good;for i in leaked.frames.indices where leaked.frames[i].step.conditionIndex != 1 {leaked.frames[i].step.purpose = .training}
        XCTAssertThrowsError(try solve(leaked))
        fixed = .standard;fixed.parameters.glow.enabled=true;fixed.parameters.glow.amount=0.1
        let proposal=try solve(good,fixed)
        XCTAssertEqual(proposal.profile.parameters.glow,fixed.parameters.glow)
        XCTAssertFalse(proposal.validationPassed,"Color evidence cannot validate inherited spatial effects")
    }
    func testCandidateCannotRegressAgainstExistingCanonicalBaseline() throws {
        var baseline=Profile.standard
        baseline.parameters.color.matrix.values=ColorReferenceSamples.matrix
        baseline.parameters.tone.enabled=true
        baseline.parameters.tone.curve = .init(knots:[.init(x:0,y:0),.init(x:0.25,y:0.2),.init(x:0.5,y:0.5),.init(x:0.75,y:0.8),.init(x:1,y:1)])
        var biased=try ColorReferenceSamples.make()
        for i in biased.frames.indices where biased.frames[i].step.purpose == .training && biased.frames[i].step.role == .target {
            for j in biased.frames[i].patches.indices {biased.frames[i].patches[j].mean[0]+=0.004;biased.frames[i].patches[j].mean[1]-=0.004}
        }
        XCTAssertThrowsError(try ToneColorSolver.solve(measurements:biased,baseline:baseline,options:.init(model:.digital,modules:[.toneColor],baseline:baseline),resources:.init()))
    }

    func testVaryingPatchRequiresOriginalPixelsForValidation() throws {
        var b=try ColorReferenceSamples.make()
        for i in b.frames.indices where b.frames[i].step.role == .input {b.frames[i].patches[0].variance=[0.0016,0.0016,0.0016]}
        XCTAssertThrowsError(try ToneColorSolver.solve(measurements:b,baseline:.standard,options:.init(model:.digital,modules:[.toneColor],baseline:.standard),resources:.init()))
    }

    func testDeveloperCheckIncludesNonlinearPixelValidation() async throws {
        let report=try await GenerationCheck.run(algorithms:[.toneColor])
        let row=try XCTUnwrap(report.results.first{$0.caseID=="patchPixelValidation"})
        XCTAssertEqual(row.status,.passed)
    }

}
