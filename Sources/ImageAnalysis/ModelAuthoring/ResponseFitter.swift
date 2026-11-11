import Foundation
import CoreImage
import ImagingCore
import ImageRendering

/// 制作数据中实际观测到的条件单元与样本归属。外推和实拍验收的覆盖范围需要独立验证。
public struct FittedConditionDomain: Codable, Equatable, Sendable {
    public let target: String
    public let axes: [ObservationAxis]
    public let coordinates: [[Double]]
    /// 二维网格中 x 轴变化最快，顺序与 ResponseExpression 一致。
    public let cellSampleIDs: [[String]]
    public init(target: String, axes: [ObservationAxis], coordinates: [[Double]], cellSampleIDs: [[String]]) {
        self.target=target; self.axes=axes; self.coordinates=coordinates; self.cellSampleIDs=cellSampleIDs
    }
}

/// 条件外观模型、可用资源与制作诊断。项目和测量摘要记录参与拟合的内容身份。
public struct ModelFitResult: Sendable {
    /// 区分手动制作与由前向外观拟合推导的结果。两类结果均需独立实拍验收。
    public enum Derivation: String, Codable, Sendable { case manual, c3ForwardFits }
    public let model: StyleModel
    public let resources: ModelResourceSet
    public let calibration: InputCalibration?
    public let baselineDigest: String
    public let projectDigest: String?
    public let consumedSampleIDs: [String]
    public let measurementDigests: [String]
    public let conditionDomains: [FittedConditionDomain]
    public let trainResidual: Double?
    public let tuneResidual: Double?
    public let unresolved: [String]
    public let algorithmVersion: String
    public let derivation: Derivation

    /// A manual/constant model can be packaged without inventing conditional measurements.
    public init(model: StyleModel, resources: ModelResourceSet, calibration: InputCalibration? = nil,
                unresolved: [String] = []) throws {
        try model.validate(); try calibration?.validate()
        self.init(model:model,resources:resources,calibration:calibration,baselineDigest:try model.digest(),
                  projectDigest:nil,consumedSampleIDs:[],measurementDigests:[],conditionDomains:[],
                  trainResidual:nil,tuneResidual:nil,unresolved:unresolved,algorithmVersion:"manual-model-v2",derivation:.manual)
    }

    /// Preserve the original model's edit/adaptation declarations while installing a constant C3 appearance.
    /// This convenience path remains manual: an externally supplied C3 result is not conditional evidence.
    public static func constant(base: AppearanceFitResult, baseline: StyleModel, resources: ModelResourceSet,
                                calibration: InputCalibration? = nil) throws -> Self {
        try baseline.validate(); try calibration?.validate()
        if let inputIdentity=base.inputIdentity,let calibration {
            guard inputIdentity == (try calibration.processingDigest()) else { throw LabError.invalid("C3 input calibration identity mismatch") }
        }
        var model=baseline; model.appearance=base.appearance
        var luts=resources.luts
        if let asset=base.generatedLUT {
            guard let id=base.generatedLUTResourceID else { throw LabError.invalid("Generated appearance LUT has no declared resource ID") }
            luts[id]=asset
        }
        try model.validate()
        return .init(model:model,resources:try .init(luts:luts,curves:resources.curves),calibration:calibration,
                     baselineDigest:try baseline.digest(),projectDigest:base.projectDigest,consumedSampleIDs:base.consumedSampleIDs,measurementDigests:[base.datasetIdentity].compactMap{$0},
                     conditionDomains:[],trainResidual:base.trainMaximumError,tuneResidual:base.tuneMaximumError,
                     unresolved:base.unresolved+["No conditional or temporal evidence was fitted"],algorithmVersion:"constant-c3-v1",derivation:.manual)
    }

    init(model:StyleModel,resources:ModelResourceSet,calibration:InputCalibration?,baselineDigest:String,
         projectDigest:String?,consumedSampleIDs:[String],measurementDigests:[String],conditionDomains:[FittedConditionDomain],
         trainResidual:Double?,tuneResidual:Double?,unresolved:[String],algorithmVersion:String,derivation:Derivation) {
        self.model=model;self.resources=resources;self.calibration=calibration;self.baselineDigest=baselineDigest
        self.projectDigest=projectDigest;self.consumedSampleIDs=consumedSampleIDs;self.measurementDigests=measurementDigests
        self.conditionDomains=conditionDomains;self.trainResidual=trainResidual;self.tuneResidual=tuneResidual
        self.unresolved=unresolved;self.algorithmVersion=algorithmVersion;self.derivation=derivation
    }
}

/// 控制变量的期望值使用轴的原始单位；最大偏差使用插值坐标（ISO/曝光时长为 log₂，其他轴为原始单位）。
public struct ConditionAxisConstraint: Codable, Equatable, Sendable {
    public let axis: ObservationAxis
    public let value: Double
    public let maximumCoordinateDelta: Double
    public init(axis:ObservationAxis,value:Double,maximumCoordinateDelta:Double=0) {
        self.axis=axis;self.value=value;self.maximumCoordinateDelta=maximumCoordinateDelta
    }
}
/// 显式记录源与目标条件的观测配对，两侧各自保留轴的身份和单位。
public struct SourceTargetConditionPair: Codable, Equatable, Sendable {
    public let sourceAxis:ConditionAxis,targetAxis:ConditionAxis
    public let sourceValue:Double,targetValue:Double
    public init(sourceAxis:ConditionAxis,targetAxis:ConditionAxis,sourceValue:Double,targetValue:Double) {
        self.sourceAxis=sourceAxis;self.targetAxis=targetAxis;self.sourceValue=sourceValue;self.targetValue=targetValue
    }
}
/// 冻结候选轴、控制条件和独立分组要求，并声明边界行为及调优选择门槛。
public struct ConditionFitDesign: Codable, Equatable, Sendable {
    public let candidateAxes:[ObservationAxis]
    public let controlledConditions:[ConditionAxisConstraint]
    public let minimumIndependentGroupsPerCell:Int
    public let sourceTargetPairs:[SourceTargetConditionPair]
    public let boundary:ResponseBoundaryPolicy
    public let minimumRelativeImprovement:Double
    public init(candidateAxes:[ObservationAxis],controlledConditions:[ConditionAxisConstraint],minimumIndependentGroupsPerCell:Int=2,
                sourceTargetPairs:[SourceTargetConditionPair]=[],boundary:ResponseBoundaryPolicy = .reject,minimumRelativeImprovement:Double=0.05) {
        self.candidateAxes=candidateAxes;self.controlledConditions=controlledConditions;self.minimumIndependentGroupsPerCell=minimumIndependentGroupsPerCell
        self.sourceTargetPairs=sourceTargetPairs;self.boundary=boundary;self.minimumRelativeImprovement=minimumRelativeImprovement
    }
    public func validate() throws {
        guard (1...2).contains(candidateAxes.count),(1...1000).contains(minimumIndependentGroupsPerCell),
              minimumRelativeImprovement.isFinite,(0..<1).contains(minimumRelativeImprovement) else { throw LabError.invalid("Invalid bounded condition fit design") }
        for (index,axis) in candidateAxes.enumerated() {
            guard !candidateAxes.prefix(index).contains(axis) else { throw LabError.invalid("Duplicate condition axes") }
            if case .feature = axis { throw LabError.unsupported("Condition authoring currently requires explicit source/target capture axes") }
        }
        for condition in controlledConditions {
            try condition.axis.validate(condition.value)
            guard condition.maximumCoordinateDelta.isFinite,condition.maximumCoordinateDelta>=0 else { throw LabError.invalid("Invalid controlled-condition tolerance") }
        }
        for pair in sourceTargetPairs { try pair.sourceAxis.validate(pair.sourceValue);try pair.targetAxis.validate(pair.targetValue) }
    }
}
/// 条件单元的外观锚点及可追溯样本分组，分别携带输入和目标侧观测。
public struct ConditionAppearanceMeasurement: Sendable {
    public let id:String
    public let sampleIDs:[String]
    public let sceneIDs:[String]
    public let sequenceIDs:[String]
    public let split:CalibrationSplit
    public let sourceConditions:CaptureConditions
    public let targetConditions:CaptureConditions
    public let controls:[ControlOverride]
    public let colors:[ColorSamplePair]
    fileprivate var c3FitDigest:String?
    /// Caller-supplied anchors are manual measurements. Only the production dataset coordinator can bind C3 derivation.
    public init(id:String,sampleIDs:[String],sceneIDs:[String],sequenceIDs:[String]=[],split:CalibrationSplit,
                sourceConditions:CaptureConditions,targetConditions:CaptureConditions,controls:[ControlOverride],colors:[ColorSamplePair]=[]) {
        self.id=id;self.sampleIDs=sampleIDs;self.sceneIDs=sceneIDs;self.sequenceIDs=sequenceIDs;self.split=split
        self.sourceConditions=sourceConditions;self.targetConditions=targetConditions;self.controls=controls;self.colors=colors;c3FitDigest=nil
    }
    func value(_ axis:ObservationAxis)->Double? {
        switch axis { case .source(let axis): return sourceConditions[axis];case .target(let axis):return targetConditions[axis];case .feature:return nil }
    }
    func context(_ model:CompiledStyleModel)->EvaluationContext {
        let stamp=FrameStamp(streamID:id,generation:1,index:0,presentationTime:0,duration:1)
        var observations=FrameObservations(stamp:stamp,sourceID:"condition-fit",calibrationID:"frozen-input",featureDigest:model.featureDigest)
        observations.captureConditions=sourceConditions
        return .init(evaluationStamp:stamp,observations:observations,targetConditions:targetConditions)
    }
}
/// 在给定条件测量上评分已编译候选，返回该评分器定义的残差。
public protocol ResponseScoring {
    func residual(_ model:CompiledStyleModel,measurements:[ConditionAppearanceMeasurement],resources:ModelResourceSet) async throws -> Double
}
/// 对手动锚点计算控制值残差。生产数据集路径使用正向渲染的像素评分。
public struct TypedControlConditionScorer: ResponseScoring {
    public init() {}
    public func residual(_ model:CompiledStyleModel,measurements:[ConditionAppearanceMeasurement],resources:ModelResourceSet) async throws -> Double {
        var maximum=0.0
        for measurement in measurements {
            guard !measurement.controls.isEmpty else { throw LabError.measurement("Control-domain scoring requires explicit target controls") }
            let controls=try StyleModelEvaluator.evaluate(model,context:measurement.context(model))
            for target in measurement.controls {
                let actual=try ControlAccess.value(target:target.target,parameters:controls.parameters,lutWeights:controls.lutWeights)
                maximum=max(maximum,try ControlInterpolation.distance(actual,target.value))
            }
        }
        return maximum
    }
}
/// 从训练条件构造有界响应候选，并依据调优残差与改进门槛选择。
public enum ResponseFitter {
    /// 从调用方提供的锚点拟合，输出手动来源的制作结果。验收数据仅参与分组校验。
    public static func fit(measurements:[ConditionAppearanceMeasurement],baseline:StyleModel,resources:ModelResourceSet,
                           design:ConditionFitDesign,options:FitOptions,scorer:any ResponseScoring = TypedControlConditionScorer()) async throws -> ModelFitResult {
        try baseline.validate();try design.validate();try options.validate()
        guard baseline.responses.isEmpty,baseline.legacyProfile == nil else { throw LabError.unsupported("Condition fitting requires a constant model baseline") }
        let selected=measurements.filter{$0.split != .acceptance}
        guard selected.count<=options.maxSamples,options.maxIterations<=1000,options.maxSamples<=100_000 else { throw LabError.invalid("Condition fit budget exceeded") }
        var ids=Set<String>(),groups=[String:CalibrationSplit](),unresolved=[String]()
        for measurement in measurements {
            guard !measurement.id.isEmpty,ids.insert(measurement.id).inserted,!measurement.sceneIDs.isEmpty,!measurement.sampleIDs.isEmpty else { throw LabError.invalid("Missing or duplicate condition measurement identity") }
            for key in measurement.sceneIDs.map({"scene:"+$0})+measurement.sequenceIDs.map({"sequence:"+$0})+measurement.sampleIDs.map({"sample:"+$0}) {
                guard !key.hasSuffix(":") else { throw LabError.invalid("Empty condition measurement group") }
                if let old=groups[key],old != measurement.split { throw LabError.invalid("Condition measurement groups cannot cross splits") }
                groups[key]=measurement.split
            }
            if measurement.split == .acceptance { continue }
            try measurement.sourceConditions.validate();try measurement.targetConditions.validate()
            try ParameterSpecification.validateOwners(measurement.controls.map(\.target))
            for control in measurement.controls {
                guard ["color.matrix","tone.curve","style.lutWeights"].contains(control.target) else { throw LabError.unsupported("Condition fitting currently owns typed color/tone/LUT controls") }
                try ParameterSpecification.lookup(control.target).validate(control.value)
            }
            for constraint in design.controlledConditions {
                guard let value=measurement.value(constraint.axis),abs(constraint.axis.coordinate(value)-constraint.axis.coordinate(constraint.value))<=constraint.maximumCoordinateDelta else {
                    throw LabError.measurement("Observed conditions do not satisfy the declared controlled variables")
                }
            }
        }
        let train=selected.filter{$0.split == .train},tune=selected.filter{$0.split == .tune}
        guard !train.isEmpty else { return try .init(model:baseline,resources:resources,unresolved:["No conditional training evidence; retaining constant appearance"]) }
        let fixed=Set(try options.fixedParameters.map{try ParameterSpecification.lookup($0).ownershipDomain})
        let owners=Set(train.flatMap{$0.controls.map(\.target)}).filter{!fixed.contains($0)}.sorted()
        guard !owners.isEmpty else { return try .init(model:baseline,resources:resources,unresolved:["No free typed condition controls"]) }
        for owner in owners {
            guard train.allSatisfy({$0.controls.contains{$0.target==owner}}) else { throw LabError.measurement("Missing training control anchor for \(owner)") }
        }
        func mean(_ records:[ConditionAppearanceMeasurement],_ owner:String) throws -> ControlValue {
            let values=records.map{$0.controls.first{$0.target==owner}!.value}
            guard var result=values.first else { throw LabError.measurement("Empty condition cell") }
            if values.allSatisfy({$0==result}) { return result }
            for (index,value) in values.dropFirst().enumerated() {
                let weight=1/Double(index+2)
                result=try ControlInterpolation.blend([result,value],weights:[1-weight,weight])
            }
            return result
        }
        var constant=baseline;constant.coverage = .init()
        for owner in owners {
            let value=try mean(train,owner)
            try ControlAccess.apply(value,target:owner,parameters:&constant.appearance.parameters,lutWeights:&constant.appearance.lutWeights)
            if owner == "tone.curve" { constant.appearance.parameters.tone.enabled=true }
        }
        var best=constant,domains=[FittedConditionDomain]()
        var trainError=try await scorer.residual(StyleModelCompiler.compile(constant),measurements:train,resources:resources)
        var tuneError=tune.isEmpty ? nil:try await scorer.residual(StyleModelCompiler.compile(constant),measurements:tune,resources:resources)
        guard trainError.isFinite,tuneError?.isFinite ?? true else { throw LabError.measurement("Nonfinite condition residual") }
        if tune.isEmpty {
            unresolved.append("No independent tune conditions; retaining the least-complex constant response")
        } else {
            func candidate(_ axes:[ObservationAxis]) throws -> (StyleModel,[FittedConditionDomain])? {
                guard train.allSatisfy({record in axes.allSatisfy{record.value($0) != nil}}) else {
                    unresolved.append("Missing axis observations; no domain claimed for \(axes)");return nil
                }
                let positions=axes.map { axis in Set(train.map{$0.value(axis)!}).sorted{axis.coordinate($0)<axis.coordinate($1)} }
                guard positions.allSatisfy({$0.count>=2 && $0.count<=min(32,options.maxComplexity)}) else {
                    unresolved.append("Response axes need independently observed bounded nodes");return nil
                }
                var cells=[[ConditionAppearanceMeasurement]]()
                for y in axes.count==2 ? positions[1]:[0] { for x in positions[0] {
                    let cell=train.filter{$0.value(axes[0])==x && (axes.count==1 || $0.value(axes[1])==y)}
                    guard !cell.isEmpty else { unresolved.append("Incomplete Cartesian training cells cannot establish a two-axis domain");return nil }
                    guard Set(cell.flatMap(\.sceneIDs)).count>=design.minimumIndependentGroupsPerCell else {
                        unresolved.append("Independent scene groups are insufficient for a response cell");return nil
                    }
                    cells.append(cell)
                } }
                let allAxes=ConditionAxis.allCases.flatMap{[ObservationAxis.source($0),.target($0)]}
                for nuisance in allAxes where !axes.contains(nuisance) {
                    let observed=Set(selected.compactMap{$0.value(nuisance)})
                    guard observed.count>1 else { continue }
                    if design.controlledConditions.contains(where:{$0.axis==nuisance}) { continue }
                    let explicitlyPaired=axes.contains { axis in
                        selected.allSatisfy { record in
                            design.sourceTargetPairs.contains { pair in
                                let matches=(axis == .source(pair.sourceAxis) && nuisance == .target(pair.targetAxis)) ||
                                    (nuisance == .source(pair.sourceAxis) && axis == .target(pair.targetAxis))
                                return matches && record.sourceConditions[pair.sourceAxis]==pair.sourceValue && record.targetConditions[pair.targetAxis]==pair.targetValue
                            }
                        }
                    }
                    if explicitlyPaired { continue }
                    let levels=Set(train.compactMap{$0.value(nuisance)})
                    let crossed=levels.count>1 && train.allSatisfy{$0.value(nuisance) != nil} && cells.allSatisfy { cell in
                        levels.allSatisfy { level in
                            Set(cell.filter{$0.value(nuisance)==level}.flatMap(\.sceneIDs)).count>=design.minimumIndependentGroupsPerCell
                        }
                    }
                    guard crossed else {
                        unresolved.append("Uncontrolled nuisance condition mapping lacks explicit pairing or crossed independent scenes: \(nuisance)")
                        return nil
                    }
                }
                var model=constant,coverage=[FittedConditionDomain]()
                for owner in owners {
                    let values=try cells.map{try mean($0,owner)}
                    if values.allSatisfy({$0==values[0]}) { continue }
                    let expression:ResponseExpression
                    if axes.count==1 { expression = .singleAxis(axis:axes[0],nodes:zip(positions[0],values).map{.init($0,$1)},boundary:design.boundary) }
                    else { expression = .twoAxisGrid(xAxis:axes[0],yAxis:axes[1],x:positions[0],y:positions[1],values:values,boundary:design.boundary) }
                    model.responses.append(.init(target:owner,expression:expression,missing:.constant(try mean(train,owner))))
                    coverage.append(.init(target:owner,axes:axes,coordinates:positions,cellSampleIDs:cells.map{Array(Set($0.flatMap(\.sampleIDs))).sorted()}))
                }
                for axis in axes {
                    switch axis {
                    case .source(let condition): if !model.observations.sourceConditions.contains(condition) { model.observations.sourceConditions.append(condition) }
                    case .target(let condition):
                        let coordinates=positions[axes.firstIndex(of:axis)!]
                        model.compatibility.targetConditions.removeAll{$0.axis==condition}
                        model.compatibility.targetConditions.append(.init(axis:condition,bounds:.init(lower:coordinates.first!,upper:coordinates.last!)))
                    case .feature: break
                    }
                }
                return (model,coverage)
            }
            // 有限候选预算包含常量基线，再依次评估单轴和双轴候选。
            let alternatives=design.candidateAxes.map{[$0]}+(design.candidateAxes.count==2 ? [design.candidateAxes]:[])
            var candidates=1 // the constant candidate consumes the first evaluation
            // 调优误差必须同时达到相对改进门槛和绝对收敛容差，才会替换当前候选。
            for axes in alternatives {
                guard candidates<options.maxIterations else { unresolved.append("Finite condition candidate budget exhausted; retaining selected simpler response");break }
                candidates+=1
                try Task.checkCancellation()
                guard let (proposed,coverage)=try candidate(axes) else { continue }
                let compiled:CompiledStyleModel
                do { compiled=try StyleModelCompiler.compile(proposed) }
                catch { unresolved.append("Unsupported candidate resource/control combination: \(error)");continue }
                let error:Double
                do { error=try await scorer.residual(compiled,measurements:tune,resources:resources) }
                catch { unresolved.append("Tune conditions are outside candidate support: \(error)");continue }
                guard error.isFinite else { throw LabError.measurement("Nonfinite condition prediction") }
                if error<(tuneError ?? .infinity)*(1-design.minimumRelativeImprovement),
                   (tuneError ?? .infinity)-error>options.convergenceTolerance {
                    best=proposed;domains=coverage;tuneError=error
                    trainError=try await scorer.residual(compiled,measurements:train,resources:resources)
                }
            }
        }
        unresolved.append("Condition cells describe development support only; independent whole-scene qualification remains pending")
        return .init(model:best,resources:resources,calibration:nil,baselineDigest:try baseline.digest(),projectDigest:nil,
                     consumedSampleIDs:Array(Set(selected.flatMap(\.sampleIDs))).sorted(),measurementDigests:[],conditionDomains:domains,
                     trainResidual:trainError,tuneResidual:tuneError,unresolved:unresolved,algorithmVersion:"bounded-condition-core-v1",derivation:.manual)
    }
}

/// Caller-owned serial B7 adapter. Patch inputs are already in the calibrated working space;
/// B2 transports them without a second input correction. This is not whole-scene qualification.
public final class B7ResponseScorer: ResponseScoring, TemporalResponsePredicting {
    private let renderer:LumeraRenderer
    private let working:WorkingImageContract
    private let execution:ExecutionProfile
    private let temporalResources:ModelResourceSet
    private let context:CIContext
    private var cachedKey:String?
    private var cachedModel:PreparedStyleModel?
    public init(renderer:LumeraRenderer,working:WorkingImageContract,execution:ExecutionProfile,resources:ModelResourceSet) throws {
        try working.validate();try execution.validate()
        guard working.dynamicRange == .sdr,execution.dynamicRange == .sdr else { throw LabError.unsupported("Condition patch validation currently requires encoded SDR") }
        self.renderer=renderer;self.working=working;self.execution=execution;temporalResources=resources
        context=CIContext(options:[.workingFormat:CIFormat.RGBAf,.cacheIntermediates:false])
    }
    fileprivate func validateCatalog(_ descriptors:[ModelResourceDescriptor],luts:[String:LUTAsset]) throws {
        var used=0
        let available=execution.budget.maxResidentBytes/2
        for descriptor in descriptors {
            let bytes=descriptor.role == .toneCurve ? descriptor.dimension*16:
                descriptor.dimension*descriptor.dimension*descriptor.dimension*32+(luts[descriptor.id]?.cubeText.utf8.count ?? 0)
            guard bytes<=available-used else { throw LabError.invalid("Condition resource catalog exceeds the reserved authoring budget") }
            used+=bytes
        }
    }
    public func residual(_ model:CompiledStyleModel,measurements:[ConditionAppearanceMeasurement],resources:ModelResourceSet) async throws -> Double {
        var maximum=0.0
        for measurement in measurements {
            guard !measurement.colors.isEmpty,measurement.colors.allSatisfy({$0.target.count==3 && $0.target.allSatisfy{$0.isFinite && (0...1).contains($0)}}) else { throw LabError.measurement("B7 condition scoring needs actual aligned input/target pixels") }
            let controls=try StyleModelEvaluator.evaluate(model,context:measurement.context(model))
            let values=try await pixels(measurement.colors.map(\.input),controls:controls,model:model,resources:resources)
            let targets=measurement.colors.flatMap(\.target)
            for (actual,target) in zip(values,targets) { maximum=max(maximum,abs(actual-target)) }
        }
        return maximum
    }
    public func predict(_ frame:ResponseSequence.Frame,controls:AutomaticControls,model:CompiledStyleModel) async throws -> [Double] {
        try await pixels(frame.inputColors,controls:controls,model:model,resources:temporalResources)
    }
    private func pixels(_ colors:[[Double]],controls:AutomaticControls,model:CompiledStyleModel,resources:ModelResourceSet) async throws -> [Double] {
        let p=controls.parameters
        guard !p.detail.isActive,!p.softening.isActive,!p.vignette.isActive,!p.glow.isActive,!p.halation.isActive,!p.noise.isActive,!p.grain.isActive,
              !colors.isEmpty,colors.count<=100_000,colors.allSatisfy({$0.count==3 && $0.allSatisfy{$0.isFinite && (0...1).contains($0)}}) else {
            throw LabError.unsupported("B7 authoring patches require bounded global color/tone inputs")
        }
        var output=[Double]();output.reserveCapacity(colors.count*3)
        for start in stride(from:0,to:colors.count,by:4096) {
            try Task.checkCancellation()
            let batch=Array(colors[start..<min(colors.count,start+4096)])
            var e=execution;e.width=batch.count;e.height=1;e.budget.maxInFlightFrames=1
            let key=model.identity+":"+String(batch.count)+":"+Digest.data(try JSON.encode(model.definition.appearance.resources))
            if cachedKey != key {
                cachedModel=nil;cachedKey=nil
                cachedModel=try ModelPreparer(renderer:renderer).prepare(model,resources:resources,execution:e);cachedKey=key
            }
            guard let prepared=cachedModel else { throw LabError.invalid("Missing authoring model preparation") }
            let rgba:[Float]=batch.flatMap{$0.map(Float.init)+[Float(1)]}
            let bytes=rgba.withUnsafeBytes{Data($0)}
            guard rgba.count==batch.count*4,bytes.count==batch.count*16 else { throw LabError.invalid("Invalid authoring RGBA32 byte layout") }
            let image=CIImage(bitmapData:bytes,bytesPerRow:batch.count*16,size:.init(width:batch.count,height:1),format:.RGBAf,colorSpace:CGColorSpace(name:CGColorSpace.sRGB))
            var source=SourceDescriptor(id:"authoring-working-patches",path:.processedPhoto);source.recipeID="working-patches"
            let recipe=InputRecipe(id:"working-patches",backend:"coreImage",version:"1",decodedRendition:.baseImage)
            let normalized=try await InputAdapter(renderer:renderer,working:working).prepare(.image(image),descriptor:source,recipe:recipe,execution:e)
            let input=try await InputNormalizer(renderer:renderer).normalize(normalized,calibration:nil,resources:ModelResourceSet())
            // These transport identities belong only to the scratch patch image. Conditions were
            // already evaluated from the original paired data and are never inferred from patches.
            var transport=controls;transport.sourceID=input.sourceID;transport.calibrationID=input.calibrationID
            let resolved=try EditResolver.resolve(.init(),automatic:transport,model:model)
            let plan=try RenderPlanner().plan(resolved,input:input,model:prepared)
            let rendered=try await renderer.render(input,plan:plan)
            var values=[Float](repeating:0,count:batch.count*4)
            values.withUnsafeMutableBytes { context.render(rendered.image,toBitmap:$0.baseAddress!,rowBytes:batch.count*16,bounds:.init(x:0,y:0,width:batch.count,height:1),format:.RGBAf,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)) }
            guard values.allSatisfy(\.isFinite) else { throw LabError.measurement("Nonfinite B7 condition readback") }
            for index in batch.indices { output += (0..<3).map{Double(values[index*4+$0])} }
        }
        return output
    }
}

private struct C3ConditionPixelScorer: ResponseScoring {
    let datasets:[String:CalibrationDataset]
    let loader:AppearanceDatasetLoader
    let calibration:InputCalibration
    let inputResources:ModelResourceSet
    let maximumSamples:Int
    let renderer:B7ResponseScorer
    func residual(_ model:CompiledStyleModel,measurements:[ConditionAppearanceMeasurement],resources:ModelResourceSet) async throws -> Double {
        var maximum=0.0
        for measurement in measurements {
            guard let dataset=datasets[measurement.id] else { throw LabError.invalid("Missing frozen condition cell") }
            // Stream one cell at a time; never retain all image pixels across the experiment.
            let loaded=try await loader.load(dataset,calibration:calibration,resources:inputResources,maximumSamples:maximumSamples)
            try AppearanceFitter.validateLoadedDataset(loaded,dataset:dataset,calibration:calibration)
            let sample=ConditionAppearanceMeasurement(id:measurement.id,sampleIDs:measurement.sampleIDs,sceneIDs:measurement.sceneIDs,
                sequenceIDs:measurement.sequenceIDs,split:measurement.split,sourceConditions:measurement.sourceConditions,targetConditions:measurement.targetConditions,
                controls:measurement.controls,colors:loaded.samples.filter{$0.split==measurement.split})
            maximum=max(maximum,try await renderer.residual(model,measurements:[sample],resources:resources))
        }
        return maximum
    }
}

extension ResponseFitter {
    static func validateBase(_ base:AppearanceFitResult?,dataset:CalibrationDataset,calibration:InputCalibration) throws {
        let selected=dataset.samples.filter{$0.split != .acceptance}
        if let base {
            let allowed=Set(selected.map(\.id))
            guard base.projectDigest==dataset.report.projectDigest,
                  Set(base.consumedSampleIDs).count==base.consumedSampleIDs.count,
                  Set(base.consumedSampleIDs).isSubset(of:allowed),
                  base.inputIdentity == (try calibration.processingDigest()) else {
                throw LabError.invalid("Conditional base does not belong to this frozen project and non-acceptance samples")
            }
        }
    }
    /// 在冻结条件单元内正向拟合外观，再比较条件响应候选。输出记录参与拟合的样本与测量摘要。
    /// 调用方直接提供的锚点走手动拟合路径。
    public static func fit(_ dataset:CalibrationDataset,baseline:StyleModel,calibration:InputCalibration,resources:ModelResourceSet,
                           inputResources:ModelResourceSet?=nil,design:ConditionFitDesign,options:FitOptions,
                           appearanceOptions:AppearanceFitOptions = .init(),loader:AppearanceDatasetLoader,
                           predictor:ReferenceAppearancePredictor,scorer:B7ResponseScorer,base:AppearanceFitResult?=nil) async throws -> ModelFitResult {
        try options.validate();try appearanceOptions.validate();try design.validate();try calibration.validate()
        guard baseline.identity==dataset.project.target,calibration.source==dataset.project.source,
              calibration.working==dataset.project.working else { throw LabError.invalid("Conditional authoring project/baseline/calibration mismatch") }
        let selected=dataset.samples.filter{$0.split != .acceptance}
        try validateBase(base,dataset:dataset,calibration:calibration)
        let initial=try base.map{try ModelFitResult.constant(base:$0,baseline:baseline,resources:resources,calibration:calibration)}
            ?? ModelFitResult(model:baseline,resources:resources,calibration:calibration)
        guard !design.controlledConditions.isEmpty else {
            return .init(model:initial.model,resources:initial.resources,calibration:initial.calibration,
                         baselineDigest:initial.baselineDigest,projectDigest:initial.projectDigest,consumedSampleIDs:initial.consumedSampleIDs,
                         measurementDigests:initial.measurementDigests,conditionDomains:initial.conditionDomains,
                         trainResidual:initial.trainResidual,tuneResidual:initial.tuneResidual,
                         unresolved:initial.unresolved+["No declared controlled variables; retaining constant appearance"],
                         algorithmVersion:initial.algorithmVersion,derivation:initial.derivation)
        }
        guard !selected.isEmpty,selected.count<=options.maxSamples else { throw LabError.measurement("Missing conditional samples or insufficient fit budget") }
        struct Conditions:Encodable { let source:CaptureConditions;let target:CaptureConditions }
        var grouped=[String:[CalibrationSample]]()
        for sample in selected {
            let key=Digest.data(try JSON.encode(Conditions(source:sample.sourceConditions,target:sample.targetConditions)))
            grouped[key,default:[]].append(sample)
        }
        let nodes=min(32,options.maxComplexity)
        guard grouped.count<=nodes*nodes else { throw LabError.measurement("Observed condition cells exceed the bounded fit design") }
        var perCell=appearanceOptions
        perCell.maximumSamples=min(perCell.maximumSamples,options.maxSamples/grouped.count)
        guard perCell.maximumSamples>=3 else { throw LabError.measurement("Condition cells exceed the numerical sample budget") }
        let correctionResources=inputResources ?? resources
        var luts=initial.resources.luts,model=initial.model
        let curves=initial.resources.curves
        try scorer.validateCatalog(model.appearance.resources,luts:luts)
        var cellPalette=Set<String>()
        var records=[ConditionAppearanceMeasurement](),datasets=[String:CalibrationDataset](),digests=[String](),unresolved=[String]()
        for key in grouped.keys.sorted() {
            try Task.checkCancellation()
            let samples=grouped[key]!,first=samples[0]
            let parent=dataset.project
            let project=CalibrationProject(id:parent.id+":"+key,target:parent.target,source:parent.source,inputRecipe:parent.inputRecipe,working:parent.working,
                samples:samples,validationPolicy:parent.validationPolicy,authorizationSource:parent.authorizationSource,inputQualificationAxes:parent.inputQualificationAxes)
            // Only non-acceptance files enter this subset or its byte validation.
            let cell=try DatasetValidator(baseDirectory:dataset.baseDirectory).validate(project)
            let training=samples.filter{$0.split == .train},tuning=samples.filter{$0.split == .tune}
            if !training.isEmpty {
                let fitted=try await AppearanceFitter.fit(cell,calibration:calibration,baseline:initial.model,resources:initial.resources,
                    options:perCell,loader:loader,predictor:predictor,inputResources:correctionResources)
                guard fitted.projectDigest==cell.report.projectDigest,fitted.inputIdentity == (try calibration.processingDigest()) else { throw LabError.invalid("C3 condition-cell provenance mismatch") }
                unresolved += fitted.unresolved.map{key+": "+$0}
                if fitted.trainMaximumError != nil {
                    for descriptor in fitted.appearance.resources {
                        if let previous=model.appearance.resources.first(where:{$0.id==descriptor.id}) {
                            guard previous==descriptor else { throw LabError.invalid("Condition cells disagree on a resource descriptor") }
                        } else { model.appearance.resources.append(descriptor) }
                    }
                    if let asset=fitted.generatedLUT {
                        guard let id=fitted.generatedLUTResourceID else { throw LabError.invalid("C3 cell LUT lacks its resource identity") }
                        luts[id]=asset
                    }
                    cellPalette.formUnion(fitted.appearance.lutWeights.map(\.resourceID))
                    guard cellPalette.count<=4 else { throw LabError.unsupported("Conditional LUT fit exceeds the four-resource runtime palette") }
                    try scorer.validateCatalog(model.appearance.resources,luts:luts)
                    let tone=fitted.appearance.parameters.tone.isActive ? fitted.appearance.parameters.tone.curve:
                        ResponseCurve(knots:(0..<32).map{.init(x:Double($0)/31,y:Double($0)/31)})
                    var controls=[ControlOverride(target:"color.matrix",value:.matrix(fitted.appearance.parameters.color.matrix)),
                                  .init(target:"tone.curve",value:.curve(tone))]
                    if !fitted.appearance.lutWeights.isEmpty { controls.append(.init(target:"style.lutWeights",value:.resourceWeights(fitted.appearance.lutWeights))) }
                    let id=key+":train"
                    var record=ConditionAppearanceMeasurement(id:id,sampleIDs:training.map(\.id),sceneIDs:Array(Set(training.map(\.sceneID))).sorted(),
                        sequenceIDs:Array(Set(training.compactMap(\.sequenceID))).sorted(),split:.train,sourceConditions:first.sourceConditions,targetConditions:first.targetConditions,controls:controls)
                    struct FitIdentity:Encodable { let project:String;let dataset:String?;let calibration:String;let appearance:AppearanceDefinition;let options:AppearanceFitOptions;let version:String }
                    let digest=Digest.data(try JSON.encode(FitIdentity(project:cell.report.projectDigest,dataset:fitted.datasetIdentity,calibration:calibration.processingDigest(),appearance:fitted.appearance,options:perCell,version:fitted.algorithmVersion)))
                    record.c3FitDigest=digest;records.append(record);datasets[id]=cell;digests.append(digest)
                }
            }
            if !tuning.isEmpty {
                let id=key+":tune"
                records.append(.init(id:id,sampleIDs:tuning.map(\.id),sceneIDs:Array(Set(tuning.map(\.sceneID))).sorted(),
                    sequenceIDs:Array(Set(tuning.compactMap(\.sequenceID))).sorted(),split:.tune,sourceConditions:first.sourceConditions,targetConditions:first.targetConditions,controls:[]))
                datasets[id]=cell
            }
        }
        // An empty LUT endpoint is not a convex palette value. Materialize exact identity when
        // some cells require a residual and others do not; never invent a fifth dynamic resource.
        if records.contains(where:{$0.controls.contains{$0.target=="style.lutWeights"}}) {
            let dimension=model.appearance.resources.first(where:{$0.role == .styleLUT})?.dimension ?? 17
            let identity=try LUTSampleGrid.identity(dimension:dimension).asset(name:"condition-neutral")
            let id="condition-neutral-"+identity.sha256
            var needsIdentity=false
            records=records.map { record in
                guard record.split == .train,!record.controls.contains(where:{$0.target=="style.lutWeights"}) else { return record }
                needsIdentity=true
                var replaced=ConditionAppearanceMeasurement(id:record.id,sampleIDs:record.sampleIDs,sceneIDs:record.sceneIDs,sequenceIDs:record.sequenceIDs,
                    split:record.split,sourceConditions:record.sourceConditions,targetConditions:record.targetConditions,
                    controls:record.controls+[.init(target:"style.lutWeights",value:.resourceWeights([.init(resourceID:id,weight:1)]))])
                replaced.c3FitDigest=record.c3FitDigest;return replaced
            }
            if needsIdentity {
                cellPalette.insert(id)
                guard cellPalette.count<=4 else { throw LabError.unsupported("Neutral conditional endpoint exceeds the four-resource palette") }
                luts[id]=identity
                if !model.appearance.resources.contains(where:{$0.id==id}) { model.appearance.resources.append(.init(id:id,sha256:identity.sha256,dimension:dimension)) }
            }
        }
        try scorer.validateCatalog(model.appearance.resources,luts:luts)
        let fittedResources=try ModelResourceSet(luts:luts,curves:curves)
        let pixelScorer=C3ConditionPixelScorer(datasets:datasets,loader:loader,calibration:calibration,inputResources:correctionResources,
                                              maximumSamples:perCell.maximumSamples,renderer:scorer)
        let fitted=try await fit(measurements:records,baseline:model,resources:fittedResources,design:design,options:options,scorer:pixelScorer)
        struct DesignIdentity:Encodable { let design:ConditionFitDesign;let options:FitOptions;let parent:String }
        digests.append(Digest.data(try JSON.encode(DesignIdentity(design:design,options:options,parent:dataset.report.projectDigest))))
        return .init(model:fitted.model,resources:fittedResources,calibration:calibration,baselineDigest:try initial.model.digest(),
            projectDigest:dataset.report.projectDigest,consumedSampleIDs:selected.map(\.id).sorted(),measurementDigests:digests.sorted(),
            conditionDomains:fitted.conditionDomains,trainResidual:fitted.trainResidual,tuneResidual:fitted.tuneResidual,
            unresolved:unresolved+fitted.unresolved,algorithmVersion:"c3-b7-condition-v1",derivation:records.contains(where:{$0.c3FitDigest != nil}) ? .c3ForwardFits:.manual)
    }
}
