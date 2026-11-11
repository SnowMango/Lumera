import XCTest
import Foundation
import CoreImage
import ImageIO
import ImagingCore
import ImageRendering
import Metal
@testable import ImageAnalysis

private struct AnalyticalAppearancePredictor: AppearancePredicting {
    var fixed: Bool = false
    func predict(_ inputs: [[Double]], parameters: StyleParameters, residual: LUTSampleGrid?) throws -> [[Double]] {
        func decode(_ v: Double) -> Double { v <= 0.04045 ? v/12.92 : pow((v+0.055)/1.055,2.4) }
        func encode(_ v: Double) -> Double { v <= 0.0031308 ? 12.92*v : 1.055*pow(v,1/2.4)-0.055 }
        return try inputs.map { input in
            let x = input.map(decode), m = parameters.color.matrix.values
            var rgb = (0..<3).map { row in encode(m[row*3]*x[0]+m[row*3+1]*x[1]+m[row*3+2]*x[2]) }
            if fixed { rgb = rgb.map { 0.04+0.9*min(1,max(0,$0)) } }
            if let residual { rgb = try residual.sample(rgb) }
            if parameters.tone.isActive { rgb = rgb.map { parameters.tone.curve.value(at:$0) } }
            return rgb.map { min(1,max(0,$0)) }
        }
    }
}
final class AppearanceFitterTests: XCTestCase {
    private func pairs(parameters: StyleParameters, fixed: Bool = false) throws -> [ColorSamplePair] {
        let predictor = AnalyticalAppearancePredictor(fixed: fixed)
        var output = [ColorSamplePair]()
        for split in [CalibrationSplit.train, .tune] {
            let offset = split == .train ? 0.0 : 0.023
            for r in 0..<5 { for g in 0..<5 { for b in 0..<5 {
                let input = [Double(r),Double(g),Double(b)].map { 0.07+$0*0.16+offset }
                let target = try predictor.predict([input], parameters: parameters, residual:nil)[0]
                output.append(.init(input:input,target:target,split:split,sceneID:split.rawValue,isGray:r==g && g==b))
            } } }
            for i in 0..<32 {
                let v = split == .train ? Double(i)/31 : (Double(i)+0.35)/32
                let input = [v,v,v]
                output.append(.init(input:input,target:try predictor.predict([input],parameters:parameters,residual:nil)[0],split:split,sceneID:split.rawValue,isGray:true))
            }
        }
        return output
    }
    func testRecoversStrongLookOutsideLegacyDomain() throws {
        var target = StyleParameters(); target.color.matrix.values = [0.55,0.25,0.02,0.04,1.25,0.02,0.12,0.05,0.72]
        let samples = try pairs(parameters:target)
        let fit = try AppearanceFitter.fit(samples:samples,baseline:StyleParameters(),options:.init(residualEnabled:false),predictor:AnalyticalAppearancePredictor())
        XCTAssertLessThanOrEqual(fit.tuneMaximumError ?? 1,0.01)
        XCTAssertLessThan(fit.appearance.parameters.color.matrix.values[0],0.6)
    }
    func testExistingLUTUsesForwardPrediction() throws {
        var target = StyleParameters(); target.color.matrix.values = [0.72,0.15,0,0.02,1.1,0.03,0.05,0.02,0.85]
        let fit = try AppearanceFitter.fit(samples:pairs(parameters:target,fixed:true),baseline:StyleParameters(),options:.init(residualEnabled:false),predictor:AnalyticalAppearancePredictor(fixed:true))
        XCTAssertLessThanOrEqual(fit.tuneMaximumError ?? 1,0.01)
    }
    func testShiftedMidGrayCurveAndNoUnnecessaryLUT() throws {
        var target = StyleParameters(); target.tone.enabled = true
        target.tone.curve = ResponseCurve(knots:(0..<32).map { let x=Double($0)/31; return .init(x:x,y:0.1+0.8*x*x) })
        let fit = try AppearanceFitter.fit(samples:pairs(parameters:target),baseline:StyleParameters(),options:.init(),predictor:AnalyticalAppearancePredictor())
        XCTAssertLessThanOrEqual(fit.tuneMaximumError ?? 1,0.01)
        XCTAssertEqual(fit.appearance.parameters.tone.curve.knots.count,32)
        XCTAssertNil(fit.residual)
        XCTAssertNotEqual(fit.appearance.parameters.tone.curve.value(at:0.5),0.5,accuracy:0.05)
    }
    func testNonlinearResidualSelectedOnlyByTune() throws {
        var samples=[ColorSamplePair]()
        for split in [CalibrationSplit.train,.tune] {
            for r in 0...8 { for g in 0...8 { for b in 0...8 {
                let offset=split == .train ? 0.0:0.37
                let x=[Double(r),Double(g),Double(b)].map{($0+offset)/(split == .train ? 8:8.74)}
                let y=[x[0]+0.24*x[0]*(1-x[0])*x[1],x[1],x[2]-0.2*x[2]*(1-x[2])*x[0]]
                samples.append(.init(input:x,target:y,split:split,sceneID:split.rawValue,isGray:r==g && g==b))
            } } }
        }
        let fit=try AppearanceFitter.fit(samples:samples,baseline:StyleParameters(),options:.init(maxIterations:200),predictor:AnalyticalAppearancePredictor())
        XCTAssertLessThanOrEqual(fit.tuneMaximumError ?? 1,0.01)
        XCTAssertNotNil(fit.residual)
    }
    func testDarkClippedDomainReturnsUnresolved() throws {
        let samples=[ColorSamplePair(input:[0.2,0.4,0.6],target:[0,0,0],split:.train,sceneID:"dark"),
                     ColorSamplePair(input:[0.5,0.1,0.3],target:[0,0,0],split:.train,sceneID:"dark"),
                     ColorSamplePair(input:[0.1,0.7,0.2],target:[0,0,0],split:.train,sceneID:"dark")]
        let fit=try AppearanceFitter.fit(samples:samples,baseline:StyleParameters(),options:.init(),predictor:AnalyticalAppearancePredictor())
        XCTAssertFalse(fit.converged);XCTAssertFalse(fit.unresolved.isEmpty)
    }
    func testIterationLimitIsNotConvergence() throws {
        var target=StyleParameters();target.color.matrix.values=[0.55,0.25,0.02,0.04,1.25,0.02,0.12,0.05,0.72]
        let fit=try AppearanceFitter.fit(samples:pairs(parameters:target),baseline:StyleParameters(),options:.init(maxIterations:1,residualEnabled:false),predictor:AnalyticalAppearancePredictor())
        XCTAssertFalse(fit.converged);XCTAssertFalse(fit.unresolved.isEmpty)
    }
    func testUnidentifiablePairsReturnUnresolved() throws {
        let samples = (0..<5).map { i in let v=0.1+Double(i)*0.1; return ColorSamplePair(input:[v,v,v],target:[v,v,v],split:.train,sceneID:"gray",isGray:true) }
        let fit = try AppearanceFitter.fit(samples:samples,baseline:StyleParameters(),options:.init(),predictor:AnalyticalAppearancePredictor())
        XCTAssertFalse(fit.converged); XCTAssertFalse(fit.unresolved.isEmpty)
    }
    func testCollapsedForwardLUTDoesNotClaimMatrixIdentifiability() throws {
        struct Collapsed: AppearancePredicting {
            func predict(_ inputs:[[Double]],parameters:StyleParameters,residual:LUTSampleGrid?) throws -> [[Double]] {
                try AnalyticalAppearancePredictor().predict(inputs,parameters:parameters,residual:residual).map { [$0[0],$0[0],$0[0]] }
            }
        }
        let predictor = Collapsed()
        let originals = try pairs(parameters:StyleParameters())
        let samples = try originals.map { pair in
            ColorSamplePair(input:pair.input,target:try predictor.predict([pair.input],parameters:StyleParameters(),residual:nil)[0],split:pair.split,sceneID:pair.sceneID,isGray:pair.isGray)
        }
        let fit = try AppearanceFitter.fit(samples:samples,baseline:StyleParameters(),options:.init(),predictor:predictor)
        XCTAssertFalse(fit.converged)
        XCTAssertTrue(fit.unresolved.contains { $0.contains("forward") && $0.contains("matrix") })
    }
    func testBaselineBindingRejectsTargetAndLUTSemanticMismatch() throws {
        let target = ModelIdentity(id:"target",name: "SDR")
        var model = StyleModel(identity:target)
        let asset = try LUTSampleGrid.identity(dimension:17).asset()
        var descriptor = ModelResourceDescriptor(id:"fixed",sha256:asset.sha256,dimension:17)
        model.appearance.resources = [descriptor]
        model.appearance.lutWeights = [.init(resourceID:"fixed",weight:1)]
        let resources = try ModelResourceSet(luts:["fixed":asset])
        XCTAssertEqual(try AppearanceFitter.validateBaseline(model,target:target,resources:resources),asset.sha256)
        var other = target; other.name = "another mode"
        XCTAssertThrowsError(try AppearanceFitter.validateBaseline(model,target:other,resources:resources))
        descriptor.inputDomain = .linearSRGB; model.appearance.resources = [descriptor]
        XCTAssertThrowsError(try AppearanceFitter.validateBaseline(model,target:target,resources:resources))
        descriptor.inputDomain = .encodedSRGB; descriptor.dimension = 33; model.appearance.resources = [descriptor]
        XCTAssertThrowsError(try AppearanceFitter.validateBaseline(model,target:target,resources:resources))
        descriptor.dimension = 17; descriptor.outOfRange = .linearExtrapolation; model.appearance.resources = [descriptor]
        XCTAssertThrowsError(try AppearanceFitter.validateBaseline(model,target:target,resources:resources))
    }
    func testGeneratedAppearanceKeepsNeutralEditResourceReachable() throws {
        var model = StyleModel(identity:.init(id:"target",name: "SDR"))
        let neutral = try LUTSampleGrid.identity(dimension:17).asset(name:"neutral")
        let descriptor = ModelResourceDescriptor(id:"neutral",sha256:neutral.sha256,dimension:17)
        model.appearance.resources = [descriptor]
        model.edits.strength = .init(neutralParameters:StyleParameters(),neutralLUTWeights:[.init(resourceID:descriptor.id,weight:1)])
        let identity = try LUTSampleGrid.identity(dimension:17)
        let generated = try LUTSampleGrid(dimension:17,samples:identity.samples.map { $0*0.9 }).asset()
        model.appearance = try AppearanceFitter.fittedAppearance(baseline:model.appearance,parameters:StyleParameters(),generatedLUT:generated)
        XCTAssertNoThrow(try model.validate())
        XCTAssertEqual(model.appearance.resources.first { $0.id == "neutral" },descriptor)
        XCTAssertEqual(model.appearance.lutWeights.first?.resourceID,"fitted-appearance-lut-"+generated.sha256)
        let catalog = try ModelResourceSet(luts:["neutral":neutral,"fitted-appearance-lut-"+generated.sha256:generated])
        for resource in model.appearance.resources { XCTAssertEqual(catalog.luts[resource.id]?.sha256,resource.sha256) }
    }
    func testProductionForwardPredictorUsesBakedFixedResidualThenTone() throws {
        guard let device=MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let renderer=try MetalRenderer(device:device,cacheLimitBytes:16*1024*1024)
        defer { renderer.releaseCaches() }
        let grid=try LUTSampleGrid.identity(dimension:17)
        let fixed=try LUTSampleGrid(dimension:17,samples:grid.samples.map{0.04+0.9*$0}).asset(name:"fixed-fixture")
        var values=grid.samples
        for i in Swift.stride(from:0,to:values.count,by:3) {
            let r=values[i],g=values[i+1],b=values[i+2]
            values[i]=r+0.1*r*(1-r)*g;values[i+2]=b-0.08*b*(1-b)*r
        }
        let residual=try LUTSampleGrid(dimension:17,samples:values)
        var parameters=StyleParameters();parameters.color.matrix.values=[0.72,0.1,0.02,0.03,0.95,0.01,0,0.07,0.85]
        parameters.tone.enabled=true
        parameters.tone.curve=ResponseCurve(knots:(0..<32).map{let x=Double($0)/31;return .init(x:x,y:0.08+0.84*x*x)})
        let inputs:[[Double]]=(0..<100).map { i in
            let r=Double((i*17)%101)/101.0
            let g=Double((i*31+7)%103)/103.0
            let b=Double((i*47+11)%107)/107.0
            return [r,g,b]
        }
        let predictor=try ReferenceAppearancePredictor(renderer:renderer,fixedLUT:fixed)
        let actual=try predictor.predict(inputs,parameters:parameters,residual:residual)
        let expected=try AnalyticalAppearancePredictor(fixed:true).predict(inputs,parameters:parameters,residual:residual)
        for (a,b) in zip(actual.flatMap{$0},expected.flatMap{$0}) { XCTAssertLessThanOrEqual(abs(a-b),0.002) }
        XCTAssertNotEqual(try predictor.combinedAsset(residual:residual)?.sha256,fixed.sha256)
    }
    func testDatasetIntegrationUsesB2AndLeavesAcceptanceFilesUnopened() async throws {
        guard let device=MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let working=WorkingImageContract(referenceRenditionID:"fixture-reference")
        let recipe=InputRecipe(id:"source",backend:"coreImage",version:"1",decodedRendition:.baseImage)
        var source=SourceDescriptor(id:"source",path:.processedPhoto);source.recipeID=recipe.id
        let targetRecipe=InputRecipe(id:"target",backend:"coreImage",version:"1",decodedRendition:.baseImage)
        var targetSource=SourceDescriptor(id:"target",path:.processedPhoto);targetSource.recipeID=targetRecipe.id
        var samples=[CalibrationSample]()
        for (index,split) in [CalibrationSplit.train,.tune,.acceptance].enumerated() {
            var pixels=[Float]()
            for y in 0..<8 { for x in 0..<8 { pixels += [Float(x%4)/5+0.03+Float(index)*0.01,Float(y%4)/5+0.04,Float((x/4)+(y/4)*2)/5+0.05,1] } }
            let bytes=try ImageCodec.encodeReference(ImageFrame(width:8,height:8,pixels:pixels))
            let name="sample-"+String(index)+".png";try bytes.write(to:directory.appendingPathComponent(name))
            let file=CalibrationFile(path:name,sha256:Digest.data(bytes),byteCount:bytes.count)
            samples.append(.init(id:name,input:file,target:file,sceneID:name,split:split))
        }
        let identity=ModelIdentity(id:"target",name: "SDR")
        let project=CalibrationProject(id:"fixture",target:identity,source:source,inputRecipe:recipe,working:working,samples:samples)
        let dataset=try DatasetValidator(baseDirectory:directory).validate(project)
        try FileManager.default.removeItem(at:directory.appendingPathComponent(samples[2].input.path))
        let effective=EffectiveInputRecipe(declared:recipe,backendVersion:ProcessInfo.processInfo.operatingSystemVersionString)
        let calibration=try InputCalibrationSolver.identity(source:source,effectiveRecipe:effective,reference:working)
        var execution=ExecutionProfile(width:8,height:8,budget:.init(maxInFlightFrames:1,maxResidentBytes:128*1024*1024));execution.precision = .float32
        let native=try LumeraRenderer(device:device,precision:.float32),reference=try MetalRenderer(device:device,cacheLimitBytes:16*1024*1024)
        defer { reference.releaseCaches() }
        let loader=try AppearanceDatasetLoader(renderer:native,execution:execution,working:working,targetSource:targetSource,targetRecipe:targetRecipe)
        let fit=try await AppearanceFitter.fit(dataset,calibration:calibration,baseline:.init(identity:identity),resources:ModelResourceSet(),options:.init(maximumSamples:256,residualEnabled:false),loader:loader,predictor:ReferenceAppearancePredictor(renderer:reference))
        XCTAssertLessThanOrEqual(fit.tuneMaximumError ?? 1,0.01)
        XCTAssertTrue(fit.fullSceneValidationPending)
        XCTAssertEqual(fit.inputIdentity,try calibration.processingDigest())
        XCTAssertNotNil(fit.datasetIdentity)
        XCTAssertEqual(fit.projectDigest,dataset.report.projectDigest)
        XCTAssertEqual(Set(fit.consumedSampleIDs),Set(samples.prefix(2).map(\.id)))
        struct CachedWrongCalibration: AppearanceDatasetLoading {
            func load(_ dataset:CalibrationDataset,calibration:InputCalibration,resources:ModelResourceSet,maximumSamples:Int) async throws -> LoadedAppearanceDataset {
                .init(samples:[],identity:String(repeating:"a",count:64),calibrationIdentity:String(repeating:"b",count:64),targetIdentity:String(repeating:"c",count:64))
            }
        }
        do {
            _ = try await AppearanceFitter.fit(dataset,calibration:calibration,baseline:.init(identity:identity),resources:ModelResourceSet(),options:.init(),loader:CachedWrongCalibration(),predictor:ReferenceAppearancePredictor(renderer:reference))
            XCTFail("Cached samples from another calibration must be rejected")
        } catch {
            XCTAssertTrue(String(describing:error).contains("calibration identity"))
        }
    }
    func testActualJPEGMetadataRejectsSourceAndTargetConditionContradictions() async throws {
        guard let device=MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let png=try ImageCodec.encodeReference(ImageFrame(width:8,height:8,pixels:Array(repeating:[Float(0.3),0.4,0.5,1],count:64).flatMap{$0}))
        let image=try XCTUnwrap(CGImageSourceCreateWithData(png as CFData,nil))
        let jpeg=NSMutableData()
        let destination=try XCTUnwrap(CGImageDestinationCreateWithData(jpeg,"public.jpeg" as CFString,1,nil))
        CGImageDestinationAddImageFromSource(destination,image,0,[kCGImagePropertyExifDictionary:[kCGImagePropertyExifISOSpeedRatings:[100]]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let bytes=jpeg as Data
        try bytes.write(to:directory.appendingPathComponent("captured.jpg"))
        let file=CalibrationFile(path:"captured.jpg",sha256:Digest.data(bytes),byteCount:bytes.count)
        let working=WorkingImageContract(referenceRenditionID:"metadata-reference")
        let recipe=InputRecipe(id:"source",backend:"coreImage",version:"1",decodedRendition:.baseImage)
        var source=SourceDescriptor(id:"source",path:.processedPhoto);source.recipeID=recipe.id
        let targetRecipe=InputRecipe(id:"target",backend:"coreImage",version:"1",decodedRendition:.baseImage)
        var targetSource=SourceDescriptor(id:"target",path:.processedPhoto);targetSource.recipeID=targetRecipe.id
        var execution=ExecutionProfile(width:8,height:8,budget:.init(maxInFlightFrames:1,maxResidentBytes:64*1024*1024));execution.precision = .float32
        let renderer=try LumeraRenderer(device:device,precision:.float32)
        let loader=try AppearanceDatasetLoader(renderer:renderer,execution:execution,working:working,targetSource:targetSource,targetRecipe:targetRecipe)
        let calibration=try InputCalibrationSolver.identity(source:source,effectiveRecipe:.init(declared:recipe,backendVersion:ProcessInfo.processInfo.operatingSystemVersionString),reference:working)
        let facts=try await InputAdapter(renderer:renderer,working:working).prepare(.image(try XCTUnwrap(CIImage(data:bytes,options:[.applyOrientationProperty:false,.expandToHDR:false]))),descriptor:source,recipe:recipe,execution:execution)
        XCTAssertEqual(facts.captureConditions.iso,100)
        for sourceContradiction in [true,false] {
            var sourceConditions=CaptureConditions(),targetConditions=CaptureConditions()
            sourceConditions.iso=sourceContradiction ? 400:100;targetConditions.iso=sourceContradiction ? 100:400
            let sample=CalibrationSample(id:"sample",input:file,target:file,sceneID:"scene",split:.train,sourceConditions:sourceConditions,targetConditions:targetConditions)
            let project=CalibrationProject(id:"metadata",target:.init(id:"target",name: "SDR"),source:source,inputRecipe:recipe,working:working,samples:[sample])
            let dataset=try DatasetValidator(baseDirectory:directory).validate(project)
            do {
                _ = try await loader.load(dataset,calibration:calibration,resources:ModelResourceSet(),maximumSamples:16)
                XCTFail("Actual source/target metadata contradiction must reject")
            } catch { XCTAssertTrue(String(describing:error).contains("Capture facts disagree")) }
        }
    }
    func testB2LoadersUseBottomLeftMasksAndGrayRegions() async throws {
        guard let device=MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let lower=CIImage(color:CIColor(red:0.5,green:0.1,blue:0.1)).cropped(to:.init(x:0,y:0,width:8,height:66))
        let upper=CIImage(color:CIColor(red:0.7,green:0.7,blue:0.7)).cropped(to:.init(x:0,y:66,width:8,height:66))
        let image=upper.composited(over:lower).cropped(to:.init(x:0,y:0,width:8,height:132))
        let bytes=try XCTUnwrap(CIContext().pngRepresentation(of:image,format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!))
        try bytes.write(to:directory.appendingPathComponent("vertical.png"))
        let file=CalibrationFile(path:"vertical.png",sha256:Digest.data(bytes),byteCount:bytes.count)
        let exclusion=SampleExclusion(x:0,y:0.5,width:1,height:0.5,reason:"Upper target half excluded")
        let masked=CalibrationSample(id:"masked",input:file,target:file,reference:file,sceneID:"masked",split:.train,alignment:.init(exclusions:[exclusion]))
        let labeled=CalibrationSample(id:"labeled",input:file,target:file,reference:file,sceneID:"labeled",split:.train)
        let working=WorkingImageContract(referenceRenditionID:"vertical-fixture")
        let recipe=InputRecipe(id:"source",backend:"coreImage",version:"1",decodedRendition:.baseImage)
        var source=SourceDescriptor(id:"source",path:.processedPhoto);source.recipeID=recipe.id
        let targetRecipe=InputRecipe(id:"target",backend:"coreImage",version:"1",decodedRendition:.baseImage)
        var targetSource=SourceDescriptor(id:"target",path:.processedPhoto);targetSource.recipeID=targetRecipe.id
        let target=ModelIdentity(id:"target",name: "SDR")
        let project=CalibrationProject(id:"vertical",target:target,source:source,inputRecipe:recipe,working:working,samples:[masked,labeled])
        let dataset=try DatasetValidator(baseDirectory:directory).validate(project)
        let calibration=try InputCalibrationSolver.identity(source:source,effectiveRecipe:.init(declared:recipe,backendVersion:ProcessInfo.processInfo.operatingSystemVersionString),reference:working)
        var execution=ExecutionProfile(width:8,height:132,budget:.init(maxInFlightFrames:1,maxResidentBytes:64*1024*1024));execution.precision = .float32
        let renderer=try LumeraRenderer(device:device,precision:.float32)
        let loader=try AppearanceDatasetLoader(renderer:renderer,execution:execution,working:working,targetSource:targetSource,targetRecipe:targetRecipe,
                                              grayRegions:["labeled":[.init(x:0,y:0.5,width:1,height:0.5)]])
        let loaded=try await loader.load(dataset,calibration:calibration,resources:ModelResourceSet(),maximumSamples:2112)
        let selected=loaded.samples.filter{$0.sceneID=="masked"},gray=loaded.samples.filter{$0.sceneID=="labeled" && $0.isGray}
        XCTAssertEqual(selected.count,528)
        XCTAssertTrue(selected.allSatisfy{$0.input[0]>2*$0.input[1]},"Upper exclusion must retain the lower red pixels")
        XCTAssertEqual(gray.count,528)
        XCTAssertTrue(gray.allSatisfy{abs($0.input[0]-$0.input[1])<0.01},"Upper gray label must select actual upper neutral pixels")
        let referenceProject=CalibrationProject(id:"reference-vertical",target:target,source:source,inputRecipe:recipe,working:working,samples:[masked])
        let referenceDataset=try DatasetValidator(baseDirectory:directory).validate(referenceProject)
        let referenceLoader=try CalibrationReferenceLoader(renderer:renderer,execution:execution,working:working,referenceSource:targetSource,referenceRecipe:targetRecipe,
                                                            referenceAlignments:["masked":.init(exclusions:[exclusion])],resources:ModelResourceSet())
        let pairs=try await referenceLoader.load(referenceDataset,split:.train,calibration:nil,maxSamples:1056)
        XCTAssertEqual(pairs.pairs.count,528)
        XCTAssertTrue(pairs.pairs.allSatisfy{$0.input[0]>2*$0.input[1]},"Input/reference exclusions must also retain lower red pixels")
    }
    func testLoadedProjectBindingRejectsForeignProjectAndAcceptanceIDs() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let working=WorkingImageContract(referenceRenditionID:"binding-fixture")
        let recipe=InputRecipe(id:"source",backend:"coreImage",version:"1",decodedRendition:.baseImage)
        var source=SourceDescriptor(id:"source",path:.processedPhoto);source.recipeID=recipe.id
        var samples=[CalibrationSample]()
        for (index,split) in [CalibrationSplit.train,.tune,.acceptance].enumerated() {
            let bytes=Data([UInt8(index)]),name="sample-\(index).bin"
            try bytes.write(to:directory.appendingPathComponent(name))
            let file=CalibrationFile(path:name,sha256:Digest.data(bytes),byteCount:bytes.count)
            samples.append(.init(id:name,input:file,target:file,sceneID:name,split:split))
        }
        let project=CalibrationProject(id:"binding",target:.init(id:"target",name: "SDR"),source:source,inputRecipe:recipe,working:working,samples:samples)
        let dataset=try DatasetValidator(baseDirectory:directory).validate(project)
        let calibration=try InputCalibrationSolver.identity(source:source,effectiveRecipe:.init(declared:recipe,backendVersion:"fixture"),reference:working)
        func loaded(_ project:String?,_ ids:[String]) throws -> LoadedAppearanceDataset {
            .init(samples:[],identity:String(repeating:"a",count:64),calibrationIdentity:try calibration.processingDigest(),targetIdentity:String(repeating:"b",count:64),projectDigest:project,consumedSampleIDs:ids)
        }
        let expected=Array(samples.prefix(2)).map(\.id)
        XCTAssertNoThrow(try AppearanceFitter.validateLoadedDataset(loaded(dataset.report.projectDigest,expected),dataset:dataset,calibration:calibration))
        XCTAssertNoThrow(try AppearanceFitter.validateLoadedDataset(loaded(nil,[]),dataset:dataset,calibration:calibration))
        XCTAssertThrowsError(try AppearanceFitter.validateLoadedDataset(loaded(String(repeating:"f",count:64),expected),dataset:dataset,calibration:calibration))
        XCTAssertThrowsError(try AppearanceFitter.validateLoadedDataset(loaded(dataset.report.projectDigest,[samples[0].id,samples[2].id]),dataset:dataset,calibration:calibration))
        XCTAssertThrowsError(try AppearanceFitter.validateLoadedDataset(loaded(dataset.report.projectDigest,[samples[0].id,samples[0].id]),dataset:dataset,calibration:calibration))
        XCTAssertThrowsError(try AppearanceFitter.validateLoadedDataset(loaded(nil,expected),dataset:dataset,calibration:calibration))
    }
    func testAcceptanceIsNeverUsedForFitting() throws {
        let samples = try pairs(parameters:StyleParameters())
        let acceptance = ColorSamplePair(input:[0.7,0.1,0.5],target:[0,1,0],split:.acceptance,sceneID:"heldout")
        let a = try AppearanceFitter.fit(samples:samples,baseline:StyleParameters(),options:.init(),predictor:AnalyticalAppearancePredictor())
        let b = try AppearanceFitter.fit(samples:samples+[acceptance],baseline:StyleParameters(),options:.init(),predictor:AnalyticalAppearancePredictor())
        XCTAssertEqual(a.appearance.parameters,b.appearance.parameters)
        XCTAssertNil(a.residual); XCTAssertNil(b.residual)
    }
}
