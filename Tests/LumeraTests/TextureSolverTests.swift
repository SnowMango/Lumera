import XCTest
import Metal
import ImagingCore
@testable import ImageAnalysis
final class TextureSolverTests:XCTestCase {
    func testOriginalFilesToProposalForBothModels() throws {
        for model in [GenerationModel.digital,.film] {
            let f=try TextureReferenceSamples.files(model:model);defer{f.cleanup()}
            let p=try TextureSolver.solve(measurements:f.measurements,baseline:f.baseline,options:.init(model:model,modules:[.texture],baseline:f.baseline),resources:.init())
            let sigma=model == .digital ? p.profile.parameters.noise.effectiveSigma(at:0.45):p.profile.parameters.grain.amount*p.profile.parameters.grain.luminanceCurve.value(at:0.45)
            XCTAssertEqual(sigma,0.025,accuracy:0.0015)
            XCTAssertTrue(p.validatedModules.contains(.texture));XCTAssertFalse(p.validationPassed)
        }
    }
    func testIndependentTemporalVarianceAndFixedPattern() throws {
        let f=try TextureReferenceSamples.make(sigma:0.02,fixedPattern:true)
        let result=try GPUTemporalTexture(device:f.device).measure(f.textures)
        XCTAssertEqual(result.training.varianceY,0.0004,accuracy:0.000012)
        XCTAssertEqual(result.validation.varianceY,0.0004,accuracy:0.000012)
        XCTAssertLessThan(result.lagSpread,0.1)
        XCTAssertGreaterThan(result.fixedVariance,0.001)
    }
    func testCorrelatedRepeatsRejected() throws {
        let f=try TextureReferenceSamples.make(sigma:0.02,fixedPattern:false)
        XCTAssertThrowsError(try GPUTemporalTexture(device:f.device).measure([f.textures[0],f.textures[0],f.textures[2],f.textures[3]]))
    }
    func testVarianceDifferenceRecoveryAndAlreadyDirtyRefusal() throws {
        let group=TextureReferenceSamples.analyticalGroups(amplitude:0.025)
        let solved=try TextureSolver.estimate(groups:group,model:.digital)
        XCTAssertEqual(solved.lowSigma,0.025,accuracy:0.00001)
        XCTAssertEqual(solved.highSigma,0.025,accuracy:0.00001)
        var dirty=group;dirty[0].target.training.varianceY=0.000001
        XCTAssertThrowsError(try TextureSolver.estimate(groups:dirty,model:.digital))
    }
    func testHeldOutExposureAndSpectrumCannotHideInAverage() throws {
        var changed=TextureReferenceSamples.analyticalGroups(amplitude:0.025)
        changed[1].target.validation.varianceY *= 2
        XCTAssertThrowsError(try TextureSolver.estimate(groups:changed,model:.digital))
        changed=TextureReferenceSamples.analyticalGroups(amplitude:0.025)
        changed[0].target.training.bands=[0.99,0.009,0.001]
        XCTAssertThrowsError(try TextureSolver.estimate(groups:changed,model:.digital))
    }
}
