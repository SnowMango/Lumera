import XCTest
import ImagingCore
import ImageRendering
@testable import ImageAnalysis

final class SolverDependencyTests:XCTestCase {
    final class ColorObserver:PatchMeasuring {
        var calls=0
        var invalid=false
        func predictColors(_ inputs:[[Double]],style:ResolvedStyle)throws->[[Double]] {
            calls += 1
            if invalid { return inputs.map{_ in [Double.nan,0,0]} }
            let p=style.parameters
            return inputs.map { rgb in
                let linear=rgb.map(ColorReferenceSamples.decode)
                return (0..<3).map { c in
                    let encoded=ColorReferenceSamples.encode((0..<3).reduce(0.0){$0+p.color.matrix.values[c*3+$1]*linear[$1]})
                    return p.tone.enabled ? p.tone.curve.value(at:encoded):encoded
                }
            }
        }
        func patches(frame:FrameMeasurements,style:ResolvedStyle,resources:RenderResources,regions:[TargetRegion])throws->[PatchMeasurement] { XCTFail("Analytical observations have no original files");return [] }
    }
    func testColorRecoveryUsesInjectedMeasurementsWithoutFilesOrGPU() throws {
        let observer=ColorObserver(),bundle=try ColorReferenceSamples.make()
        let result=try ToneColorSolver.solve(measurements:bundle,baseline:.standard,options:.init(model:.digital,modules:[.toneColor],baseline:.standard),resources:.init(),measurement:observer)
        XCTAssertEqual(observer.calls,2)
        XCTAssertTrue(result.validatedModules.contains(.toneColor))
        XCTAssertFalse(result.validationPassed)
        for (a,b) in zip(result.profile.parameters.color.matrix.values,ColorReferenceSamples.matrix) {XCTAssertEqual(a,b,accuracy:0.03)}
    }
    func testNonfiniteCandidateMeasurementsAreRejected() throws {
        let observer=ColorObserver();observer.invalid=true
        XCTAssertThrowsError(try ToneColorSolver.solve(measurements:ColorReferenceSamples.make(),baseline:.standard,options:.init(model:.digital,modules:[.toneColor],baseline:.standard),resources:.init(),measurement:observer))
    }
    func testStaleResourcesRejectBeforeCallingMeasurement() throws {
        let observer=ColorObserver();var bundle=try ColorReferenceSamples.make();bundle.resourceDigests=[:]
        XCTAssertThrowsError(try ToneColorSolver.solve(measurements:bundle,baseline:.standard,options:.init(model:.digital,modules:[.toneColor],baseline:.standard),resources:.init(),measurement:observer))
        XCTAssertEqual(observer.calls,0)
    }
}

extension SolverDependencyTests {
    func testSpatialSolversRejectIncompleteEvidenceWithoutCallingServices() throws {
        struct Never:DetailMeasuring,LightMeasuring,TextureMeasuring {
            func detail(frame:FrameMeasurements,style:ResolvedStyle,resources:RenderResources)throws->DetailObservation {XCTFail("Incomplete input reached measurement");throw LabError.noMetal}
            func light(frame:FrameMeasurements,style:ResolvedStyle,resources:RenderResources)throws->LightSignature {XCTFail("Incomplete input reached measurement");throw LabError.noMetal}
            func texture(frames:[FrameMeasurements],styles:[ResolvedStyle],resources:RenderResources,seeds:[UInt32])throws->TemporalTexture {XCTFail("Incomplete input reached measurement");throw LabError.noMetal}
        }
        let bundle=MeasurementBundle(frames:[],resourceDigests:try GenerationResources().validatedDigests())
        XCTAssertThrowsError(try DetailSolver.solve(measurements:bundle,baseline:.standard,options:.init(model:.digital,modules:[.detail],baseline:.standard),resources:.init(),measurement:Never()))
        XCTAssertThrowsError(try GlowSolver.solve(measurements:bundle,baseline:.standard,options:.init(model:.digital,modules:[.glow],baseline:.standard),resources:.init(),measurement:Never()))
        XCTAssertThrowsError(try TextureSolver.solve(measurements:bundle,baseline:.standard,options:.init(model:.digital,modules:[.texture],baseline:.standard),resources:.init(),measurement:Never()))
    }
}

extension SolverDependencyTests {
    func testStandaloneWrappersRejectBeforeCreatingContext() throws {
        var calls=0
        let makeContext:()throws->GenerationExecutionContext = {calls += 1;throw LabError.noMetal}
        let bundle=MeasurementBundle(frames:[],resourceDigests:[:])
        for module in [AlgorithmID.toneColor,.detail,.glow,.texture] {
            let options=GenerationOptions(model:.digital,modules:[module],baseline:.standard)
            switch module {
            case .toneColor:XCTAssertThrowsError(try ToneColorSolver.solve(measurements:bundle,baseline:.standard,options:options,resources:.init(),makeContext:makeContext))
            case .detail:XCTAssertThrowsError(try DetailSolver.solve(measurements:bundle,baseline:.standard,options:options,resources:.init(),makeContext:makeContext))
            case .glow:XCTAssertThrowsError(try GlowSolver.solve(measurements:bundle,baseline:.standard,options:options,resources:.init(),makeContext:makeContext))
            default:XCTAssertThrowsError(try TextureSolver.solve(measurements:bundle,baseline:.standard,options:options,resources:.init(),makeContext:makeContext))
            }
        }
        XCTAssertThrowsError(try GenerationPreparation.prepare(captures:.init(protocolVersion:"old",records:[],issues:[]),resources:.init(),makeContext:makeContext))
        XCTAssertThrowsError(try CombinedValidation.run(proposal:.init(profile:.standard,evidence:[],unresolved:[],resourceDigests:[:]),baseline:.standard,measurements:bundle,resources:.init(),makeContext:makeContext))
        XCTAssertEqual(calls,0)
    }
    func testOriginalPatchObservationsMustHaveUniqueIDsAndThreeFiniteChannels() throws {
        struct Patches:PatchMeasuring {
            let mean:[Double];let duplicate:Bool
            func predictColors(_ inputs:[[Double]],style:ResolvedStyle)throws->[[Double]]{inputs}
            func patches(frame:FrameMeasurements,style:ResolvedStyle,resources:RenderResources,regions:[TargetRegion])throws->[PatchMeasurement]{
                let values=regions.map{PatchMeasurement(id:$0.id,kind:$0.kind,mean:mean,variance:[0,0,0],clippedFraction:0,pixelCount:1000)}
                return duplicate ? values+[values[0]]:values
            }
        }
        var frame=try ColorReferenceSamples.make().frames.first{$0.step.role == .input}!
        frame.sourceURL=URL(fileURLWithPath:"/unused-injected-original.png")
        frame.pose = .init(coefficients:[1,0,0,0,1,0,0,0,1])
        let pair=ColorPatchPair(group:frame.step.pairKey,id:"gray-0",kind:.gray,input:[0.3,0.3,0.3],target:[0.3,0.3,0.3],training:false)
        for mean in [[Double](),[0.3],[.nan,0.3,0.3]] {
            XCTAssertThrowsError(try ToneColorSolver.predictions([pair],profile:.standard,measurement:Patches(mean:mean,duplicate:false),frames:[frame]))
        }
        XCTAssertThrowsError(try ToneColorSolver.predictions([pair],profile:.standard,measurement:Patches(mean:[0.3,0.3,0.3],duplicate:true),frames:[frame]))
    }
}
