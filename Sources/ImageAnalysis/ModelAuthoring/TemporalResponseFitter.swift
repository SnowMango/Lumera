import Foundation
import ImagingCore

/// 按场景分组的时序观测。同帧统计与声明延迟的统计必须分别拟合，时间及延迟以秒计。
public struct ResponseSequence: Codable, Sendable {
    public enum Mode: String, Codable, Sendable { case sameFrame, declaredDelay }
    public struct Frame: Codable, Sendable {
        public let record: DecisionRecord
        public let targetPresentationTime: Double
        public let measurements: [Double]
        public let inputColors: [[Double]]
        public init(record:DecisionRecord,targetPresentationTime:Double,measurements:[Double],inputColors:[[Double]] = []) {
            self.record=record;self.targetPresentationTime=targetPresentationTime;self.measurements=measurements;self.inputColors=inputColors
        }
    }
    public let id: String
    public let sceneID: String
    public let split: CalibrationSplit
    public let mode: Mode
    public let captureDelaySeconds: Double?
    public let captureUncertaintySeconds: Double?
    public let frames: [Frame]
    public init(id:String,sceneID:String,split:CalibrationSplit,mode:Mode,captureDelaySeconds:Double?,captureUncertaintySeconds:Double?,frames:[Frame]) {
        self.id=id;self.sceneID=sceneID;self.split=split;self.mode=mode;self.captureDelaySeconds=captureDelaySeconds
        self.captureUncertaintySeconds=captureUncertaintySeconds;self.frames=frames
    }
}
/// 单个适应目标的搜索边界。时间常数以秒计，迟滞使用目标的控制域。
public struct TemporalFitBounds: Codable, Equatable, Sendable {
    public let target: String
    public let timeConstantSeconds: NumericBounds
    public let hysteresis: NumericBounds
    public init(target:String,timeConstantSeconds:NumericBounds,hysteresis:NumericBounds) {
        self.target=target;self.timeConstantSeconds=timeConstantSeconds;self.hysteresis=hysteresis
    }
}
/// 约束时间常数和迟滞的搜索、采集时间不确定性及优化预算。
public struct TemporalFitOptions: Codable, Equatable, Sendable {
    public let bounds: [TemporalFitBounds]
    public let maximumCaptureUncertaintySeconds: Double
    public let optimization: FitOptions
    public init(bounds:[TemporalFitBounds],maximumCaptureUncertaintySeconds:Double,optimization:FitOptions = .init()) {
        self.bounds=bounds;self.maximumCaptureUncertaintySeconds=maximumCaptureUncertaintySeconds;self.optimization=optimization
    }
    public func validate() throws {
        try optimization.validate();try ParameterSpecification.validateOwners(bounds.map(\.target))
        guard (1...3).contains(bounds.count),maximumCaptureUncertaintySeconds.isFinite,maximumCaptureUncertaintySeconds>=0,
              optimization.maxIterations<=1000,optimization.maxSamples<=100_000 else { throw LabError.invalid("Invalid bounded temporal fit options") }
        for bound in bounds {
            guard ["color.matrix","tone.curve","style.lutWeights"].contains(bound.target) else { throw LabError.unsupported("Temporal authoring currently fits typed color/tone/LUT controls") }
            try bound.timeConstantSeconds.validate();try bound.hysteresis.validate()
            guard bound.timeConstantSeconds.lower>=0,bound.hysteresis.lower>=0 else { throw LabError.invalid("Temporal search bounds must be nonnegative") }
        }
    }
}
/// 绑定编译模型和序列内容的适应策略、残差与未解决事项。
public struct TemporalFitResult: Sendable {
    public let policy: AdaptationPolicy
    public let modelDigest: String
    public let sequenceIDs: [String]
    /// 绑定模型、参与拟合的序列、选项与策略的内容摘要。实拍时序资格需独立验收。
    public let measurementDigest: String?
    public let trainResidual: Double?
    public let tuneResidual: Double?
    public let iterations: Int
    public let converged: Bool
    public let options: TemporalFitOptions
    public let unresolved: [String]
    public let algorithmVersion: String
}
/// 将帧及适应后的自动控制映射为与实测向量逐项对应的预测值。
public protocol TemporalResponsePredicting {
    func predict(_ frame:ResponseSequence.Frame,controls:AutomaticControls,model:CompiledStyleModel) async throws -> [Double]
}
/// 数值控制域的时序预测器，适用于开发证据。
public struct TypedControlTemporalPredictor: TemporalResponsePredicting {
    public let targets:[String]
    public init(targets:[String]) { self.targets=targets }
    public func predict(_ frame:ResponseSequence.Frame,controls:AutomaticControls,model:CompiledStyleModel) async throws -> [Double] {
        try ParameterSpecification.validateOwners(targets)
        var result=[Double]()
        for target in targets {
            switch try ControlAccess.value(target:target,parameters:controls.parameters,lutWeights:controls.lutWeights) {
            case .scalar(let value): result.append(value)
            case .matrix(let matrix): result += matrix.values
            case .curve(let curve): result += try ControlInterpolation.canonicalKnots(curve).map(\.y)
            case .resourceWeights(let weights): result += model.lutResourceIDs.sorted().map { id in weights.first{$0.resourceID==id}?.weight ?? 0 }
            }
        }
        return result
    }
}

/// 用运行时适应归约逻辑离线拟合时间常数与迟滞。
public enum TemporalResponseFitter {
    /// 训练序列用于搜索，调优序列用于报告残差，验收序列只参与分组校验。
    /// 时序声明或可辨识性不足时，可保留原适应策略并记录原因。
    public static func fit(_ sequences:[ResponseSequence],model:CompiledStyleModel,policy:ValidationPolicy,
                           options:TemporalFitOptions,predictor:any TemporalResponsePredicting) async throws -> TemporalFitResult {
        try policy.validate();try options.validate()
        let selected=sequences.filter{$0.split != .acceptance}
        var unresolved=[String](),evaluations=0
        var measurementDigest:String?
        func result(_ adaptation:AdaptationPolicy,_ train:Double?,_ tune:Double?,_ converged:Bool) -> TemporalFitResult {
            .init(policy:adaptation,modelDigest:model.identity,sequenceIDs:selected.map(\.id),measurementDigest:measurementDigest,trainResidual:train,tuneResidual:tune,
                  iterations:evaluations,converged:converged,options:options,unresolved:unresolved,
                  algorithmVersion:"temporal-core-reducer-v1")
        }
        var groups=[String:CalibrationSplit](),ids=Set<String>()
        for sequence in sequences {
            guard !sequence.id.isEmpty,!sequence.sceneID.isEmpty,ids.insert(sequence.id).inserted else { throw LabError.invalid("Missing or duplicate response sequence identity") }
            if let split=groups[sequence.sceneID],split != sequence.split { throw LabError.invalid("Temporal scenes cannot cross splits") }
            groups[sequence.sceneID]=sequence.split
        }
        guard selected.contains(where:{$0.split == .train}) else {
            unresolved.append("No training temporal sequence; retaining manual policy")
            return result(model.definition.adaptation,nil,nil,false)
        }
        guard Set(selected.map(\.mode)).count==1 else { throw LabError.invalid("Same-frame and declared-delay modes must be fitted separately") }
        guard selected.reduce(0,{$0+$1.frames.count})<=options.optimization.maxSamples else { throw LabError.invalid("Temporal frame budget exceeded") }
        guard selected.allSatisfy({ sequence in
            guard let delay=sequence.captureDelaySeconds,let uncertainty=sequence.captureUncertaintySeconds else { return false }
            return delay.isFinite && uncertainty.isFinite && uncertainty>=0 && uncertainty<=options.maximumCaptureUncertaintySeconds
        }) else {
            unresolved.append("Unknown capture delay or insufficient capture uncertainty prevents timing fitting")
            return result(model.definition.adaptation,nil,nil,false)
        }
        let resourceDigest=Digest.data(try JSON.encode(model.definition.appearance.resources))
        var contentIdentity:String?
        for sequence in selected {
            guard sequence.frames.count>=3 else { throw LabError.measurement("A temporal sequence needs stable and transition observations") }
            var previous:FrameStamp?
            for frame in sequence.frames {
                let record=frame.record,context=record.context,stamp=context.evaluationStamp
                try stamp.validate();try context.observations.validate()
                guard record.version==1,record.modelDigest==model.identity,record.resourceDigest==resourceDigest,record.edits == EditRequest(),
                      !frame.measurements.isEmpty,frame.measurements.allSatisfy(\.isFinite),frame.targetPresentationTime.isFinite,
                      abs(frame.targetPresentationTime-sequence.captureDelaySeconds!-stamp.presentationTime)<=sequence.captureUncertaintySeconds!+1e-9 else {
                    throw LabError.invalid("Temporal measurement identity, edits or declared target timing mismatch")
                }
                if case .lock = record.event { throw LabError.unsupported("Locked controls cannot identify model response timing") }
                if case .unlock = record.event { throw LabError.unsupported("Unlock edits cannot identify model response timing") }
                guard let current=record.currentInput else { throw LabError.invalid("Temporal evidence requires current prepared-input facts") }
                do {
                    try current.validate()
                    try ObservationPacketValidator.validate(context.observations,current:current,requirements:model.definition.observations)
                    guard current.stamp == stamp,current.sourceID == context.observations.sourceID,
                          current.calibrationID == context.observations.calibrationID,current.effectiveRecipeDigest == record.inputRecipeDigest else {
                        throw LabError.invalid("Temporal prepared-input identity mismatch")
                    }
                }
                let identity=context.observations.sourceID+":"+context.observations.calibrationID+":"+record.inputRecipeDigest
                if let contentIdentity,contentIdentity != identity { throw LabError.invalid("Temporal source/calibration/recipe changed across sequences") }
                contentIdentity=identity
                switch sequence.mode {
                case .sameFrame: guard context.observations.stamp == stamp else { throw LabError.invalid("Same-frame measurement contains delayed observations") }
                case .declaredDelay:
                    guard context.observations.stamp.index<stamp.index,model.definition.observations.validity.maxAgeFrames>0 else {
                        throw LabError.invalid("Delayed temporal evidence needs a declared observation delay")
                    }
                }
                if case .reset = record.event { previous=nil }
                if let previous {
                    guard previous.streamID==stamp.streamID,previous.generation==stamp.generation,previous.index<stamp.index,
                          previous.presentationTime<stamp.presentationTime else { throw LabError.invalid("Temporal frame chronology changed without a separate sequence") }
                }
                previous=stamp
            }
        }
        struct Identity:Encodable { let model:String;let sequences:[ResponseSequence];let options:TemporalFitOptions;let policy:ValidationPolicy }
        measurementDigest=Digest.data(try JSON.encode(Identity(model:model.identity,sequences:selected,options:options,policy:policy)))
        let train=selected.filter{$0.split == .train},tune=selected.filter{$0.split == .tune}
        var adaptation=model.definition.adaptation
        let fixedDomains=Set(try options.optimization.fixedParameters.map{try ParameterSpecification.lookup($0).ownershipDomain})
        let bounds=options.bounds.filter{!fixedDomains.contains($0.target)}
        guard !bounds.isEmpty else {
            unresolved.append("All temporal parameters are explicitly fixed")
            return result(adaptation,nil,nil,false)
        }
        // Reconstruct the same raw automatic fallback used by live DecisionReplay.
        // Adaptation output is deliberately not fed back into the evaluator.
        var automatic=[String:[AutomaticControls]]()
        for sequence in selected {
            var fallback:FallbackSnapshot?,trajectory=[AutomaticControls]()
            for frame in sequence.frames {
                if case .reset = frame.record.event { fallback=nil }
                var context=frame.record.context
                if let supplied=context.fallback,supplied != fallback { throw LabError.invalid("Replay fallback disagrees with reconstructed history") }
                context.fallback=fallback
                let desired=try StyleModelEvaluator.evaluate(model,context:context)
                trajectory.append(desired)
                fallback = .init(controls:desired,stamp:context.evaluationStamp)
            }
            automatic[sequence.id]=trajectory
        }
        for bound in bounds {
            var transition=false
            for sequence in train {
                var previous:ControlValue?
                for (frame,control) in zip(sequence.frames,automatic[sequence.id]!) {
                    if case .reset = frame.record.event { previous=nil }
                    let value=try ControlAccess.value(target:bound.target,parameters:control.parameters,lutWeights:control.lutWeights)
                    if let previous,try ControlInterpolation.distance(previous,value)>1e-9 { transition=true }
                    previous=value
                }
            }
            guard transition else {
                unresolved.append("No independently observed within-sequence transition for \(bound.target); retaining manual policy")
                return result(model.definition.adaptation,nil,nil,false)
            }
            if !adaptation.rules.contains(where:{$0.target==bound.target}) { adaptation.rules.append(.init(target:bound.target,timeConstantSeconds:bound.timeConstantSeconds.lower)) }
        }
        struct Score { let loss:Double;let maximum:Double;let predictions:[Double] }
        func score(_ policy:AdaptationPolicy,_ sequences:[ResponseSequence],capture:Bool=false) async throws -> Score {
            var loss=0.0,maximum=0.0,count=0,predictions=[Double]()
            for sequence in sequences {
                var state:AdaptationState?
                for (frame,desired) in zip(sequence.frames,automatic[sequence.id]!) {
                    try Task.checkCancellation()
                    if case .reset = frame.record.event { state=nil }
                    let reduced=try AdaptationReducer.reduce(desired,state:state,stamp:frame.record.context.evaluationStamp,event:frame.record.event,policy:policy)
                    let values=try await predictor.predict(frame,controls:reduced.controls,model:model)
                    guard values.count==frame.measurements.count,values.allSatisfy(\.isFinite) else { throw LabError.measurement("Invalid temporal forward measurement") }
                    for (actual,target) in zip(values,frame.measurements) { let error=abs(actual-target);loss += error*error;maximum=max(maximum,error);count+=1 }
                    if capture { predictions += values }
                    state=reduced.state
                }
            }
            guard loss.isFinite,maximum.isFinite else { throw LabError.measurement("Temporal residual overflow") }
            return .init(loss:loss/Double(max(1,count)),maximum:maximum,predictions:predictions)
        }
        struct SearchDimension { let rule:Int;let isTau:Bool;let lower:Double;let upper:Double }
        var dimensions=[SearchDimension]()
        for bound in bounds {
            let index=adaptation.rules.firstIndex{$0.target==bound.target}!
            adaptation.rules[index].timeConstantSeconds=min(bound.timeConstantSeconds.upper,max(bound.timeConstantSeconds.lower,adaptation.rules[index].timeConstantSeconds))
            adaptation.rules[index].hysteresis=min(bound.hysteresis.upper,max(bound.hysteresis.lower,adaptation.rules[index].hysteresis))
            dimensions += [.init(rule:index,isTau:true,lower:bound.timeConstantSeconds.lower,upper:bound.timeConstantSeconds.upper),
                           .init(rule:index,isTau:false,lower:bound.hysteresis.lower,upper:bound.hysteresis.upper)]
        }
        let free=dimensions.filter{$0.upper>$0.lower}
        let sensitivityBudget=2*free.count
        guard options.optimization.maxIterations>1+sensitivityBudget else {
            unresolved.append("Finite search budget cannot establish timing forward sensitivity")
            return result(model.definition.adaptation,nil,nil,false)
        }
        let searchBudget=options.optimization.maxIterations-sensitivityBudget
        var best=try await score(adaptation,train);evaluations=1
        var intervals=dimensions.map{($0.lower,$0.upper)},converged=false
        while evaluations<searchBudget {
            var maximumWidth=0.0
            for index in dimensions.indices {
                let dimension=dimensions[index],interval=intervals[index]
                if interval.1==interval.0 { continue }
                var chosen=dimension.isTau ? adaptation.rules[dimension.rule].timeConstantSeconds:adaptation.rules[dimension.rule].hysteresis
                for step in 0...4 where evaluations<searchBudget {
                    let coordinate=interval.0+(interval.1-interval.0)*Double(step)/4
                    var candidate=adaptation
                    if dimension.isTau { candidate.rules[dimension.rule].timeConstantSeconds=coordinate }
                    else { candidate.rules[dimension.rule].hysteresis=coordinate }
                    let measured=try await score(candidate,train);evaluations+=1
                    if measured.loss<best.loss {
                        adaptation=candidate;best=measured;chosen=coordinate
                    }
                }
                let radius=(interval.1-interval.0)/4
                intervals[index]=(max(dimension.lower,chosen-radius),min(dimension.upper,chosen+radius))
                maximumWidth=max(maximumWidth,(intervals[index].1-intervals[index].0)/max(1,dimension.upper-dimension.lower))
            }
            if best.loss<=pow(options.optimization.convergenceTolerance,2) || maximumWidth<=options.optimization.convergenceTolerance { converged=true;break }
        }
        // 使用未加阻尼的前向预测检查独立时序方向。仅控制变化不足以辨识时序，例如矩阵变化作用于全黑像素。
        var directions=[[Double]]()
        for dimension in free {
            var lower=adaptation,upper=adaptation
            if dimension.isTau {
                lower.rules[dimension.rule].timeConstantSeconds=dimension.lower
                upper.rules[dimension.rule].timeConstantSeconds=dimension.upper
            } else {
                lower.rules[dimension.rule].hysteresis=dimension.lower
                upper.rules[dimension.rule].hysteresis=dimension.upper
            }
            let lo=try await score(lower,train,capture:true),hi=try await score(upper,train,capture:true)
            evaluations+=2
            let delta=zip(lo.predictions,hi.predictions).map{$1-$0}
            let norm=sqrt(delta.reduce(0){$0+$1*$1})
            guard norm.isFinite,norm>max(1e-10,options.optimization.convergenceTolerance)*sqrt(Double(max(1,delta.count))) else {
                unresolved.append("Unobservable forward timing direction; retaining manual policy")
                return result(model.definition.adaptation,nil,nil,false)
            }
            directions.append(delta.map{$0/norm})
        }
        if !directions.isEmpty {
            let gram=directions.map{a in directions.map{b in zip(a,b).reduce(0){$0+$1.0*$1.1}}}
            do { _ = try GenerationMath.solve(gram,Array(repeating:1,count:directions.count)) }
            catch {
                unresolved.append("Coupled forward timing directions are unresolved; retaining manual policy")
                return result(model.definition.adaptation,nil,nil,false)
            }
        }
        let tuned=tune.isEmpty ? nil:try await score(adaptation,tune).maximum
        if !converged { unresolved.append("Finite temporal search budget exhausted before convergence") }
        if tune.isEmpty { unresolved.append("No independent tune sequence; temporal generalization remains unknown") }
        if !policy.thresholds.contains(where:{$0.domain == .temporal}) { unresolved.append("No frozen temporal threshold; timing qualification remains insufficient") }
        unresolved.append("Independent timing and whole-scene pixel validation remain pending")
        return result(adaptation,best.maximum,tuned,converged)
    }
}
