import Foundation
import CoreImage
import ImagingCore
import ImageRendering

/// 对齐的外观颜色样本及其内容身份，记录实际使用的样本和输入校准身份。
public struct LoadedAppearanceDataset: Sendable {
    public let samples:[ColorSamplePair]
    public let identity:String
    public let calibrationIdentity:String
    public let targetIdentity:String
    public let projectDigest:String?
    public let consumedSampleIDs:[String]
    public init(samples:[ColorSamplePair],identity:String,calibrationIdentity:String,targetIdentity:String,projectDigest:String?=nil,consumedSampleIDs:[String]=[]) {
        self.samples=samples;self.identity=identity;self.calibrationIdentity=calibrationIdentity;self.targetIdentity=targetIdentity
        self.projectDigest=projectDigest;self.consumedSampleIDs=consumedSampleIDs
    }
}
public protocol AppearanceDatasetLoading {
    func load(_ dataset:CalibrationDataset,calibration:InputCalibration,resources:ModelResourceSet,maximumSamples:Int) async throws -> LoadedAppearanceDataset
}
/// 按显式目标源描述和配方载入训练与调优颜色对，验收图像留待独立验证。
/// 对齐、排除区和调用方声明的灰区使用 Core Image 左下原点的归一化坐标。
public final class AppearanceDatasetLoader: AppearanceDatasetLoading {
    private let adapter:InputAdapter,normalizer:InputNormalizer
    private let execution:ExecutionProfile,working:WorkingImageContract
    private let targetSource:SourceDescriptor,targetRecipe:InputRecipe
    private let grayRegions:[String:[Region]]
    private let context:CIContext
    public init(renderer:LumeraRenderer,execution:ExecutionProfile,working:WorkingImageContract,
                targetSource:SourceDescriptor,targetRecipe:InputRecipe,grayRegions:[String:[Region]]=[:]) throws {
        try execution.validate();try working.validate();try targetSource.validate();try targetRecipe.validate()
        guard execution.dynamicRange == .sdr,working.dynamicRange == .sdr,targetSource.recipeID == targetRecipe.id else {
            throw LabError.invalid("Appearance fitting requires explicit SDR target source/recipe")
        }
        for regions in grayRegions.values { for region in regions { try region.validate() } }
        self.adapter=try InputAdapter(renderer:renderer,working:working);self.normalizer=InputNormalizer(renderer:renderer)
        self.execution=execution;self.working=working;self.targetSource=targetSource;self.targetRecipe=targetRecipe;self.grayRegions=grayRegions
        context=CIContext(options:[.workingColorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!, .workingFormat:CIFormat.RGBAf,.cacheIntermediates:false])
    }
    /// 对输入应用校准，并按每张图分配的样本预算与目标外观对齐取样。
    /// 当前要求显式恒等对齐和相同像素尺寸；一般几何配准由调用方在采样前完成。
    public func load(_ dataset:CalibrationDataset,calibration:InputCalibration,resources:ModelResourceSet,maximumSamples:Int) async throws -> LoadedAppearanceDataset {
        guard let recipe=dataset.project.inputRecipe,dataset.project.working == working,calibration.working == working,
              calibration.source == dataset.project.source else { throw LabError.invalid("Frozen input calibration/project mismatch") }
        let selected=dataset.samples.filter{$0.split != .acceptance}
        guard !selected.isEmpty,maximumSamples>=selected.count else { throw LabError.measurement("Missing train/tune images or insufficient budget") }
        // C3 fits one target condition, not a condition-response surface.
        let targetConditions=selected[0].targetConditions
        guard selected.allSatisfy({$0.targetConditions == targetConditions}) else { throw LabError.measurement("Select a fixed target-condition subset before appearance fitting") }
        var preparation=execution
        preparation.budget.maxResidentBytes=try CalibrationReferenceLoader.workspaceBudget(total:execution.budget.maxResidentBytes,maxSamples:maximumSamples)
        let bytesBudget=preparation.budget.maxResidentBytes/2,each=maximumSamples/selected.count
        var samples=[ColorSamplePair](),targetID:String?,identities=[String]()
        for sample in selected {
            try Task.checkCancellation()
            let inputBytes=try CalibrationReferenceLoader.checkedBytes(sample.input,baseDirectory:dataset.baseDirectory,maximumBytes:bytesBudget)
            let targetBytes=try CalibrationReferenceLoader.checkedBytes(sample.target,baseDirectory:dataset.baseDirectory,maximumBytes:bytesBudget)
            let input=try await adapter.prepare(Self.source(inputBytes,descriptor:dataset.project.source,recipe:recipe),descriptor:dataset.project.source,recipe:recipe,execution:preparation)
            try CalibrationReferenceLoader.validateConditionAgreement(manifest:sample.sourceConditions,observed:input.captureConditions)
            let normalized=try await normalizer.normalize(input,calibration:calibration,resources:resources)
            let target=try await adapter.prepare(Self.source(targetBytes,descriptor:targetSource,recipe:targetRecipe),descriptor:targetSource,recipe:targetRecipe,execution:preparation)
            try CalibrationReferenceLoader.validateConditionAgreement(manifest:sample.targetConditions,observed:target.captureConditions)
            struct Target:Encodable { let source:SourceDescriptor;let recipe:String;let working:String }
            let id=Digest.data(try JSON.encode(Target(source:targetSource,recipe:target.effectiveRecipe.digest(),working:working.digest())))
            if let previous=targetID,previous != id { throw LabError.measurement("Target effective recipes changed within fixed-condition dataset") }
            targetID=id
            samples += try samplePixels(normalized,target,sample:sample,budget:each)
            identities += [sample.input.sha256,sample.target.sha256,Digest.data(try JSON.encode(sample.alignment))]
        }
        guard let targetID,!samples.isEmpty else { throw LabError.measurement("No comparable appearance samples") }
        struct Identity:Encodable { let version:String;let project:String;let calibration:String;let target:String;let files:[String];let execution:ExecutionProfile;let grayRegions:[String:[Region]] }
        let calibrationID=try calibration.processingDigest()
        let identity=Digest.data(try JSON.encode(Identity(version:"appearance-b2-loader-v1",project:dataset.report.projectDigest,
            calibration:calibrationID,target:targetID,files:identities,execution:execution,grayRegions:grayRegions)))
        return .init(samples:samples,identity:identity,calibrationIdentity:calibrationID,targetIdentity:targetID,
                     projectDigest:dataset.report.projectDigest,consumedSampleIDs:selected.map(\.id).sorted())
    }
    private static func source(_ bytes:Data,descriptor:SourceDescriptor,recipe:InputRecipe) throws -> SourceImage {
        if descriptor.path == .raw || descriptor.path == .proRAW { return .rawData(bytes) }
        guard descriptor.path == .processedPhoto,let rendition=recipe.decodedRendition,
              let image=CIImage(data:bytes,options:[.applyOrientationProperty:false,.expandToHDR:rendition == .systemReconstructed]) else {
            throw LabError.unsupported("Appearance file loader requires explicit processed photo or RAW input; video needs a host loader")
        }
        return .image(image)
    }
    private func samplePixels(_ input:PreparedInput,_ target:NormalizedInput,sample:CalibrationSample,budget:Int) throws -> [ColorSamplePair] {
        let t=sample.alignment.inputToTarget
        guard t.count==6,t.allSatisfy(\.isFinite),abs(t[0]*t[3]-t[1]*t[2])>1e-12 else { throw LabError.measurement("Invalid appearance alignment") }
        let w=input.width,h=input.height,tw=Double(target.width),th=Double(target.height)
        let transform=CGAffineTransform(a:t[0]*tw/Double(w),b:t[1]*th/Double(w),c:t[2]*tw/Double(h),d:t[3]*th/Double(h),tx:t[4]*tw,ty:t[5]*th)
        let aligned=target.image.transformed(by:transform.inverted())
        let stride=max(1,Int(ceil(sqrt(Double(w)*Double(h)/Double(budget)))))
        let space=CGColorSpace(name:CGColorSpace.sRGB)!,gray=grayRegions[sample.id] ?? []
        var result=[ColorSamplePair]()
        for y in Swift.stride(from:0,to:h,by:128) { for x in Swift.stride(from:0,to:w,by:128) {
            try Task.checkCancellation()
            let width=min(128,w-x),height=min(128,h-y),bounds=CGRect(x:x,y:y,width:width,height:height)
            var a=[Float](repeating:0,count:width*height*4),b=a
            a.withUnsafeMutableBytes{context.render(input.image,toBitmap:$0.baseAddress!,rowBytes:width*16,bounds:bounds,format:.RGBAf,colorSpace:space)}
            b.withUnsafeMutableBytes{context.render(aligned,toBitmap:$0.baseAddress!,rowBytes:width*16,bounds:bounds,format:.RGBAf,colorSpace:space)}
            // CI bitmap rows are top-first within this tile; regions use bottom-left image coordinates.
            for row in 0..<height where (y+height-1-row)%stride==0 { for col in 0..<width where (x+col)%stride==0 {
                let px=(Double(x+col)+0.5)/Double(w),py=(Double(y+height-row)-0.5)/Double(h)
                let tx=t[0]*px+t[2]*py+t[4],ty=t[1]*px+t[3]*py+t[5]
                guard (0...1).contains(tx),(0...1).contains(ty) else { continue }
                if sample.alignment.exclusions.contains(where:{tx >= $0.x && tx < $0.x+$0.width && ty >= $0.y && ty < $0.y+$0.height}) { continue }
                let i=(row*width+col)*4,source=(0..<3).map{Double(a[i+$0])},destination=(0..<3).map{Double(b[i+$0])}
                guard (source+destination).allSatisfy({$0.isFinite && (0...1).contains($0)}) else { throw LabError.measurement("Appearance readback outside encoded SDR domain") }
                result.append(.init(input:source,target:destination,split:sample.split,sceneID:sample.sceneID,sequenceID:sample.sequenceID,
                    isGray:gray.contains{tx >= $0.x && tx < $0.x+$0.width && ty >= $0.y && ty < $0.y+$0.height}))
                if result.count==budget { return result }
            } }
        } }
        return result
    }
}

extension AppearanceFitter {
    /// 在冻结的目标条件下通过正向渲染拟合外观，返回与数据集及输入校准绑定的结果。
    /// 整场景与独立验收另行测量。
    public static func fit(_ dataset:CalibrationDataset,calibration:InputCalibration,baseline:StyleModel,resources:ModelResourceSet,
                           options:AppearanceFitOptions,loader:any AppearanceDatasetLoading,predictor:ReferenceAppearancePredictor,
                           inputResources:ModelResourceSet? = nil) async throws -> AppearanceFitResult {
        try calibration.validate();try options.validate()
        let expected=try validateBaseline(baseline,target:dataset.project.target,resources:resources)
        guard predictor.fixedLUTDigest == expected else { throw LabError.invalid("Forward predictor does not own the baseline fixed LUT") }
        let loaded=try await loader.load(dataset,calibration:calibration,resources:inputResources ?? resources,maximumSamples:options.maximumSamples)
        try validateLoadedDataset(loaded,dataset:dataset,calibration:calibration)
        var result=try fit(samples:loaded.samples,baseline:baseline.appearance.parameters,options:options,predictor:predictor)
        let appearance=try fittedAppearance(baseline:baseline.appearance,parameters:result.appearance.parameters,generatedLUT:result.generatedLUT)
        result.appearance=appearance;result.inputIdentity=loaded.calibrationIdentity;result.datasetIdentity=loaded.identity
        result.projectDigest=loaded.projectDigest;result.consumedSampleIDs=loaded.consumedSampleIDs.sorted()
        if calibration.qualifications.isEmpty { result.unresolved.append("Input calibration has no measured qualification") }
        result.unresolved.append("Whole-scene GPU and independent acceptance validation remain pending")
        return result
    }
    static func validateLoadedDataset(_ loaded:LoadedAppearanceDataset,dataset:CalibrationDataset,calibration:InputCalibration) throws {
        guard loaded.calibrationIdentity == (try calibration.processingDigest()) else {
            throw LabError.invalid("Loaded appearance calibration identity does not match the frozen input calibration")
        }
        if let project=loaded.projectDigest {
            let expected=Set(dataset.samples.filter{$0.split != .acceptance}.map(\.id))
            guard project == dataset.report.projectDigest else { throw LabError.invalid("Loaded appearance project identity does not match the frozen project") }
            guard Set(loaded.consumedSampleIDs)==expected,loaded.consumedSampleIDs.count==expected.count else {
                throw LabError.invalid("Loaded appearance samples must match the exact non-acceptance project subset")
            }
        } else {
            guard loaded.consumedSampleIDs.isEmpty else { throw LabError.invalid("Sample provenance requires a bound project identity") }
        }
    }
    /// Keeps the complete catalog because neutral edits/adaptation/fallbacks may still reference it.
    /// Builder/runtime preparation remains responsible for bounded reachable-palette validation.
    static func fittedAppearance(baseline:AppearanceDefinition,parameters:StyleParameters,generatedLUT:LUTAsset?) throws -> AppearanceDefinition {
        var appearance=baseline;appearance.parameters=parameters
        if let asset=generatedLUT {
            let cube=try asset.decodedCube()
            let descriptor=ModelResourceDescriptor(id:"fitted-appearance-lut-"+asset.sha256,sha256:asset.sha256,dimension:cube.size)
            if let existing=appearance.resources.first(where:{$0.id == descriptor.id}) {
                guard existing == descriptor else { throw LabError.invalid("Generated LUT resource ID conflicts with an existing descriptor") }
            } else { appearance.resources.append(descriptor) }
            appearance.lutWeights=[.init(resourceID:descriptor.id,weight:1)]
        }
        return appearance
    }
    static func validateBaseline(_ baseline:StyleModel,target:ModelIdentity,resources:ModelResourceSet) throws -> String? {
        try baseline.validate()
        guard baseline.identity == target else { throw LabError.invalid("Appearance baseline target identity differs from the frozen project") }
        guard baseline.responses.isEmpty,baseline.legacyProfile == nil else {
            throw LabError.unsupported("Fixed-condition appearance fitting requires a constant model baseline")
        }
        let weights=baseline.appearance.lutWeights
        guard weights.count<=1,weights.allSatisfy({$0.weight == 1}) else { throw LabError.unsupported("Appearance fit requires one fixed LUT or none") }
        return try weights.first.map { weight -> String in
            guard let asset=resources.luts[weight.resourceID],let descriptor=baseline.appearance.resources.first(where:{$0.id==weight.resourceID}),
                  descriptor.role == .styleLUT,descriptor.sha256 == asset.sha256,
                  descriptor.inputDomain == .encodedSRGB,descriptor.outputDomain == .encodedSRGB,
                  descriptor.inputBounds == NumericBounds(lower:0,upper:1),descriptor.outOfRange == .clamp,
                  asset.boundaryPolicy != .extrapolate else { throw LabError.invalid("Fixed LUT resource or sampling contract mismatch") }
            let cube=try asset.decodedCube()
            guard cube.size == descriptor.dimension,cube.rgba.enumerated().allSatisfy({
                $0.offset%4 == 3 || ($0.element.isFinite && (0...1).contains($0.element) && descriptor.outputBounds.contains(Double($0.element)))
            }) else { throw LabError.invalid("Fixed LUT dimension or output bounds mismatch") }
            return asset.sha256
        }
    }

}
