import XCTest
import Foundation
import Metal
import ImagingCore
import ImageRendering
@testable import ImageAnalysis

final class CameraResponseFitterTests: XCTestCase {
    func testConstantRemainsConstantWithoutEvidence() throws {
        let model=CameraModel(identity:.init(id:"fixture",camera:"synthetic",mode:"SDR"))
        let result=try CameraFitResult(model:model,resources:ModelResourceSet())
        XCTAssertEqual(result.model,model)
        XCTAssertEqual(result.derivation,.manual)
        XCTAssertTrue(result.conditionDomains.isEmpty)
        XCTAssertNil(result.projectDigest)
    }
    func samples(_ cells:[(Double,Double?)],split:CalibrationSplit,twoAxis:Bool) -> [ConditionAppearanceMeasurement] {
        cells.enumerated().flatMap { index,cell in (0..<2).map { repetition in
            var source=CaptureConditions();source.iso=100
            var target=CaptureConditions();target.iso=cell.0;target.whiteBalanceTemperatureKelvin=cell.1
            let gain=0.4+0.3*log2(cell.0/100)/2+(twoAxis ? 0.2*((cell.1 ?? 3000)-3000)/3000:0)
            let id="\(split.rawValue)-\(index)-\(repetition)"
            return .init(id:id,sampleIDs:[id],sceneIDs:[id],split:split,sourceConditions:source,targetConditions:target,
                         controls:[.init(target:"color.matrix",value:.matrix(.init(values:[gain,0,0,0,gain,0,0,0,gain])))])
        } }
    }
    func baseline() -> CameraModel { .init(identity:.init(id:"fixture",camera:"synthetic",mode:"SDR")) }
    func testOneAxisPreferredOverUnsupportedTwoAxis() async throws {
        let measurements=samples([(100,nil),(400,nil)],split:.train,twoAxis:false)+samples([(150,nil),(300,nil)],split:.tune,twoAxis:false)
        let design=ConditionFitDesign(candidateAxes:[.target(.iso),.target(.whiteBalanceTemperatureKelvin)],controlledConditions:[.init(axis:.source(.iso),value:100)])
        let fit=try await CameraResponseFitter.fit(measurements:measurements,baseline:baseline(),resources:ModelResourceSet(),design:design,options:.init())
        XCTAssertEqual(fit.conditionDomains.first?.axes,[.target(.iso)])
        XCTAssertLessThan(fit.tuneResidual ?? 1,1e-8)
        XCTAssertEqual(fit.derivation,.manual)
        XCTAssertTrue(fit.model.coverage.evidenceDigests.isEmpty)
    }
    func testIndistinguishableTuneDataKeepsConstant() async throws {
        let measurements=samples([(100,nil),(400,nil)],split:.train,twoAxis:false)+samples([(200,nil)],split:.tune,twoAxis:false)
        let fit=try await CameraResponseFitter.fit(measurements:measurements,baseline:baseline(),resources:ModelResourceSet(),design:.init(candidateAxes:[.target(.iso)],controlledConditions:[.init(axis:.source(.iso),value:100)]),options:.init())
        XCTAssertTrue(fit.model.responses.isEmpty)
        XCTAssertTrue(fit.conditionDomains.isEmpty)
    }
    func testMissingConditionCellCannotGrantCoverage() async throws {
        let measurements=samples([(100,3000),(400,3000),(100,6000)],split:.train,twoAxis:true)+samples([(200,4500)],split:.tune,twoAxis:true)
        let fit=try await CameraResponseFitter.fit(measurements:measurements,baseline:baseline(),resources:ModelResourceSet(),design:.init(candidateAxes:[.target(.iso),.target(.whiteBalanceTemperatureKelvin)],controlledConditions:[.init(axis:.source(.iso),value:100)]),options:.init())
        XCTAssertFalse(fit.conditionDomains.contains{$0.axes.count==2})
        XCTAssertTrue(fit.unresolved.contains{$0.contains("Cartesian")})
    }
    func testCompleteControlledGridPredictsIndependentIntermediateConditions() async throws {
        let measurements=samples([(100,3000),(400,3000),(100,6000),(400,6000)],split:.train,twoAxis:true)+samples([(150,4000),(300,5000)],split:.tune,twoAxis:true)
        let fit=try await CameraResponseFitter.fit(measurements:measurements,baseline:baseline(),resources:ModelResourceSet(),design:.init(candidateAxes:[.target(.iso),.target(.whiteBalanceTemperatureKelvin)],controlledConditions:[.init(axis:.source(.iso),value:100)]),options:.init())
        XCTAssertTrue(fit.conditionDomains.contains{$0.axes.count==2})
        let compiled=try CameraModelCompiler.compile(fit.model)
        for (iso,kelvin) in [(125.0,3500.0),(250.0,5500.0)] {
            let stamp=FrameStamp(streamID:"heldout",generation:1,index:0,presentationTime:0,duration:1)
            let observations=FrameObservations(stamp:stamp,sourceID:"source",calibrationID:"calibration",featureDigest:compiled.featureDigest)
            var target=CaptureConditions();target.iso=iso;target.whiteBalanceTemperatureKelvin=kelvin
            let controls=try CameraModelEvaluator.evaluate(compiled,context:.init(evaluationStamp:stamp,observations:observations,targetConditions:target))
            XCTAssertEqual(controls.parameters.color.matrix.values[0],0.4+0.3*log2(iso/100)/2+0.2*(kelvin-3000)/3000,accuracy:1e-8)
        }
    }

    func testSourceTargetNamespacesRequireAnExplicitObservedPairing() async throws {
        let original=samples([(100,nil),(400,nil)],split:.train,twoAxis:false)+samples([(150,nil),(300,nil)],split:.tune,twoAxis:false)
        let measurements=original.map { record -> ConditionAppearanceMeasurement in
            var source=CaptureConditions();source.iso=record.targetConditions.iso
            var target=CaptureConditions();target.iso=40000/source.iso!;target.exposureBiasEV=0
            return .init(id:record.id,sampleIDs:record.sampleIDs,sceneIDs:record.sceneIDs,split:record.split,sourceConditions:source,targetConditions:target,controls:record.controls)
        }
        let unavailable=try await CameraResponseFitter.fit(measurements:measurements,baseline:baseline(),resources:ModelResourceSet(),
            design:.init(candidateAxes:[.source(.iso)],controlledConditions:[.init(axis:.target(.exposureBiasEV),value:0)]),options:.init())
        XCTAssertTrue(unavailable.model.responses.isEmpty)
        XCTAssertTrue(unavailable.unresolved.contains{$0.contains("mapping")})
        let pairs=measurements.map{SourceTargetConditionPair(sourceAxis:.iso,targetAxis:.iso,sourceValue:$0.sourceConditions.iso!,targetValue:$0.targetConditions.iso!)}
        let fitted=try await CameraResponseFitter.fit(measurements:measurements,baseline:baseline(),resources:ModelResourceSet(),
            design:.init(candidateAxes:[.source(.iso)],controlledConditions:[.init(axis:.target(.exposureBiasEV),value:0)],sourceTargetPairs:pairs),options:.init())
        XCTAssertEqual(fitted.conditionDomains.first?.axes,[.source(.iso)])
        XCTAssertEqual(fitted.model.observations.sourceConditions,[.iso])
        XCTAssertLessThan(fitted.tuneResidual ?? 1,1e-8)
    }
    func testTargetAxisCannotAbsorbUncontrolledSourceChanges() async throws {
        let original=samples([(100,nil),(400,nil)],split:.train,twoAxis:false)+samples([(150,nil),(300,nil)],split:.tune,twoAxis:false)
        for nuisance in [ConditionAxis.iso,.exposureDurationSeconds] {
            let records=original.map { record -> ConditionAppearanceMeasurement in
                var source=record.sourceConditions
                source[nuisance] = nuisance == .iso ? record.targetConditions.iso!*2:record.targetConditions.iso!/100000
                var target=record.targetConditions;target.exposureBiasEV=0
                return .init(id:record.id,sampleIDs:record.sampleIDs,sceneIDs:record.sceneIDs,split:record.split,sourceConditions:source,targetConditions:target,controls:record.controls)
            }
            let fit=try await CameraResponseFitter.fit(measurements:records,baseline:baseline(),resources:ModelResourceSet(),design:.init(candidateAxes:[.target(.iso)],controlledConditions:[.init(axis:.target(.exposureBiasEV),value:0)]),options:.init())
            XCTAssertTrue(fit.model.responses.isEmpty,"Nuisance source changes cannot be attributed to target ISO")
            XCTAssertTrue(fit.unresolved.contains{$0.contains("nuisance")})
        }
    }
    func testConditionalAcceptanceAndCandidateBudgetStayIsolated() async throws {
        let records=samples([(100,nil),(400,nil)],split:.train,twoAxis:false)+samples([(150,nil),(300,nil)],split:.tune,twoAxis:false)
        let design=ConditionFitDesign(candidateAxes:[.target(.iso)],controlledConditions:[.init(axis:.source(.iso),value:100)])
        let held=ConditionAppearanceMeasurement(id:"held",sampleIDs:["held"],sceneIDs:["held"],split:.acceptance,sourceConditions:.init(),targetConditions:.init(),controls:[.init(target:"invalid",value:.scalar(.nan))])
        let a=try await CameraResponseFitter.fit(measurements:records,baseline:baseline(),resources:ModelResourceSet(),design:design,options:.init())
        let b=try await CameraResponseFitter.fit(measurements:records+[held],baseline:baseline(),resources:ModelResourceSet(),design:design,options:.init())
        XCTAssertEqual(a.model,b.model)
        XCTAssertFalse(b.consumedSampleIDs.contains("held"))
        let bounded=try await CameraResponseFitter.fit(measurements:records,baseline:baseline(),resources:ModelResourceSet(),design:design,options:.init(maxIterations:1))
        XCTAssertTrue(bounded.model.responses.isEmpty)
        XCTAssertTrue(bounded.unresolved.contains{$0.contains("budget")})
    }
    func testProductionBaseCannotRelabelForeignOrAcceptanceTraining() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let bytes=Data([1,2,3]);try bytes.write(to:directory.appendingPathComponent("immutable"))
        let file=CalibrationFile(path:"immutable",sha256:Digest.data(bytes),byteCount:bytes.count)
        let heldBytes=Data([4,5,6]);try heldBytes.write(to:directory.appendingPathComponent("held"))
        let heldFile=CalibrationFile(path:"held",sha256:Digest.data(heldBytes),byteCount:heldBytes.count)
        let recipe=InputRecipe(id:"source",backend:"coreImage",version:"1",decodedRendition:.baseImage)
        var source=SourceDescriptor(id:"source",path:.processedPhoto);source.recipeID=recipe.id
        let working=WorkingImageContract(referenceRenditionID:"reference")
        let project=CalibrationProject(id:"project",target:baseline().identity,source:source,inputRecipe:recipe,working:working,samples:[
            .init(id:"train",input:file,target:file,sceneID:"train",split:.train),.init(id:"held",input:heldFile,target:heldFile,sceneID:"held",split:.acceptance)])
        let dataset=try DatasetValidator(baseDirectory:directory).validate(project)
        let calibration=try InputCalibrationSolver.identity(source:source,effectiveRecipe:.init(declared:recipe,backendVersion:"fixture"),reference:working)
        var base=AppearanceFitResult(appearance:baseline().appearance,residual:nil,generatedLUT:nil,trainMaximumError:nil,tuneMaximumError:nil,
            converged:false,iterations:0,unresolved:[],algorithmVersion:"fixture",options:.init(),curveDiagnostics:nil,residualIterations:0,
            inputIdentity:try calibration.processingDigest(),datasetIdentity:String(repeating:"a",count:64))
        base.projectDigest=dataset.report.projectDigest;base.consumedSampleIDs=["train"]
        XCTAssertNoThrow(try CameraResponseFitter.validateBase(base,dataset:dataset,calibration:calibration))
        let constant=try CameraFitResult.constant(base:base,baseline:baseline(),resources:ModelResourceSet(),calibration:calibration)
        XCTAssertEqual(constant.projectDigest,dataset.report.projectDigest);XCTAssertEqual(constant.consumedSampleIDs,["train"])
        base.projectDigest=String(repeating:"b",count:64)
        XCTAssertThrowsError(try CameraResponseFitter.validateBase(base,dataset:dataset,calibration:calibration))
        base.projectDigest=dataset.report.projectDigest;base.consumedSampleIDs=["held"]
        XCTAssertThrowsError(try CameraResponseFitter.validateBase(base,dataset:dataset,calibration:calibration))
        base.consumedSampleIDs=["train","train"]
        XCTAssertThrowsError(try CameraResponseFitter.validateBase(base,dataset:dataset,calibration:calibration))
        base.projectDigest=nil;base.consumedSampleIDs=[]
        XCTAssertThrowsError(try CameraResponseFitter.validateBase(base,dataset:dataset,calibration:calibration))
    }
    func testProductionCellsUseC3AndB7WithoutAcceptanceOrInputResourceAliasing() async throws {
        guard let device=MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let working=WorkingImageContract(referenceRenditionID:"conditional-working")
        let recipe=InputRecipe(id:"source",backend:"coreImage",version:"1",decodedRendition:.baseImage)
        var source=SourceDescriptor(id:"source",path:.processedPhoto);source.recipeID=recipe.id
        let targetRecipe=InputRecipe(id:"target",backend:"coreImage",version:"1",decodedRendition:.baseImage)
        var targetSource=SourceDescriptor(id:"target",path:.processedPhoto);targetSource.recipeID=targetRecipe.id
        let rows:[(Double,CalibrationSplit)]=[(100,.train),(100,.train),(400,.train),(400,.train),(150,.tune),(300,.tune),(250,.acceptance)]
        var records=[CalibrationSample]()
        for (index,row) in rows.enumerated() {
            var pixels=[Float](),targets=[Float]()
            let gain=0.6+0.3*log2(row.0/100)/2
            for y in 0..<8 { for x in 0..<8 {
                let rgb=[Double(x%4)/5+0.03+Double(index)*0.003,Double(y%4)/5+0.04,Double((x/4)+(y/4)*2)/5+0.05]
                let transformed=rgb.map { value -> Double in
                    let linear=value<=0.04045 ? value/12.92:pow((value+0.055)/1.055,2.4)
                    let v=linear*gain
                    return v<=0.0031308 ? 12.92*v:1.055*pow(v,1/2.4)-0.055
                }
                pixels += rgb.map(Float.init)+[1];targets += transformed.map(Float.init)+[1]
            } }
            func file(_ name:String,_ pixels:[Float]) throws -> CalibrationFile {
                let bytes=try ImageCodec.encodeReference(ImageFrame(width:8,height:8,pixels:pixels))
                try bytes.write(to:directory.appendingPathComponent(name))
                return .init(path:name,sha256:Digest.data(bytes),byteCount:bytes.count)
            }
            let input=try file("source-\(index).png",pixels),target=try file("target-\(index).png",targets)
            var sourceConditions=CaptureConditions();sourceConditions.iso=100
            var targetConditions=CaptureConditions();targetConditions.iso=row.0
            records.append(.init(id:"sample-\(index)",input:input,target:target,sceneID:"scene-\(index)",split:row.1,sourceConditions:sourceConditions,targetConditions:targetConditions))
        }
        let identity=TargetIdentity(id:"target",camera:"synthetic",mode:"SDR")
        let project=CalibrationProject(id:"conditional",target:identity,source:source,inputRecipe:recipe,working:working,samples:records)
        let dataset=try DatasetValidator(baseDirectory:directory).validate(project)
        for file in [records.last!.input,records.last!.target] { try FileManager.default.removeItem(at:directory.appendingPathComponent(file.path)) }
        var calibration=try InputCalibrationSolver.identity(source:source,effectiveRecipe:.init(declared:recipe,backendVersion:ProcessInfo.processInfo.operatingSystemVersionString),reference:working)
        let correction=try LUTSampleGrid.identity(dimension:17).asset(name:"input-only")
        var correctionDescriptor=ModelResourceDescriptor(id:"input-only",sha256:correction.sha256,dimension:17);correctionDescriptor.role = .correctionLUT
        calibration.resources=[correctionDescriptor]
        let inputResources=try ModelResourceSet(luts:[correctionDescriptor.id:correction])
        let fixed=try LUTSampleGrid.identity(dimension:17).asset(name:"fixed-style")
        let styleResources=try ModelResourceSet(luts:["fixed-style":fixed])
        var baseline=CameraModel(identity:identity)
        baseline.appearance.resources=[.init(id:"fixed-style",sha256:fixed.sha256,dimension:17)]
        baseline.appearance.lutWeights=[.init(resourceID:"fixed-style",weight:1)]
        var execution=ExecutionProfile(width:8,height:8,budget:.init(maxInFlightFrames:1,maxResidentBytes:128*1024*1024));execution.precision = .float32
        let renderer=try LumeraRenderer(device:device,precision:.float32),reference=try MetalRenderer(device:device,cacheLimitBytes:16*1024*1024)
        defer { reference.releaseCaches() }
        let loader=try AppearanceDatasetLoader(renderer:renderer,execution:execution,working:working,targetSource:targetSource,targetRecipe:targetRecipe)
        let scorer=try B7CameraResponseScorer(renderer:renderer,working:working,execution:execution,resources:styleResources)
        let fit=try await CameraResponseFitter.fit(dataset,baseline:baseline,calibration:calibration,resources:styleResources,inputResources:inputResources,
            design:.init(candidateAxes:[.target(.iso)],controlledConditions:[.init(axis:.source(.iso),value:100)]),options:.init(maxSamples:4096),
            appearanceOptions:.init(maxIterations:40,maximumSamples:1024,residualEnabled:false),loader:loader,predictor:ReferenceAppearancePredictor(renderer:reference,fixedLUT:fixed),scorer:scorer)
        XCTAssertEqual(fit.derivation,.c3ForwardFits)
        XCTAssertEqual(fit.projectDigest,dataset.report.projectDigest)
        XCTAssertEqual(Set(fit.consumedSampleIDs),Set(records.dropLast().map(\.id)))
        XCTAssertFalse(fit.model.responses.isEmpty)
        XCTAssertLessThanOrEqual(fit.tuneResidual ?? 1,0.01)
        XCTAssertFalse(fit.resources.luts.keys.contains("input-only"))
        XCTAssertTrue(fit.resources.luts.keys.contains("fitted-appearance-lut-"+fixed.sha256))
        XCTAssertTrue(fit.model.coverage.evidenceDigests.isEmpty)
        XCTAssertFalse(fit.measurementDigests.isEmpty)
    }

}
