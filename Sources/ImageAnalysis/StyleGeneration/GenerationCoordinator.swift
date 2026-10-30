import Foundation
import ImagingCore

public struct GenerationValidationFailure:LocalizedError,Sendable {
    public let report:GenerationValidationReport
    public var errorDescription:String? {"组合验证未通过，保留原风格。请查看各照片组的失败指标。"}
}
public enum GenerationCoordinator {
    public static let featureModules:Set<AlgorithmID>=[.toneColor,.detail,.texture,.glow]
    public static func requiredTargets(for modules:Set<AlgorithmID>)->Set<CaptureTarget> {
        var targets:Set<CaptureTarget>=[.composite]
        if modules.contains(.texture){targets.insert(.flat)}
        if modules.contains(.glow){targets.insert(.light)}
        return targets
    }
    public static func requiredAlgorithms(for modules:Set<AlgorithmID>)->Set<AlgorithmID> {
        modules.union([.independentLUT,.targetDetection,.captureQuality,.conditionResponse,.combinedValidation])
    }
    public static func generate(captures:CaptureSet,baseline:Profile,options:GenerationOptions,resources:GenerationResources,eligibility:GenerationEligibility,progress:@Sendable(GenerationProgress)->Void = {_ in})async throws->GenerationProposal {
        try Task.checkCancellation()
        guard !options.modules.isEmpty,options.modules.isSubset(of:featureModules),requiredAlgorithms(for:options.modules).isSubset(of:eligibility.algorithms) else {throw LabError.invalid("当前选择未取得完整自检资格；实拍定位/质量待验证不能由合成结果代替")}
        try baseline.validate()
        guard baseline.responses.isEmpty else{throw LabError.invalid("自动生成需要无既有条件响应的起点；已有响应可继续在手动工作台调整")}
        guard try baseline.effectDigest()==options.baseline.effectDigest() else{throw LabError.invalid("生成起点已改变，请重新开始")}
        let measurements=try GenerationPreparation.prepare(captures:captures,resources:resources,modules:options.modules,progress:progress)
        var working=baseline,evidence=[AlgorithmCaseResult](),unresolved=[String](),validated=Set<AlgorithmID>()
        // Staged fitting is explicit. Every resulting effect must be checked again
        // together against the original, unmodified baseline before publication.
        if options.modules.contains(.detail){working.parameters.detail.enabled=false;working.parameters.softening.enabled=false}
        if options.modules.contains(.glow){working.parameters.glow.enabled=false;working.parameters.halation.enabled=false}
        if options.modules.contains(.texture){working.parameters.noise.enabled=false;working.parameters.grain.enabled=false}
        if options.modules.contains(.toneColor) {
            progress(.init(stage:"生成明暗与颜色建议",completed:0))
            let p=try ToneColorSolver.solve(measurements:measurements,baseline:working,options:options,resources:resources)
            working=p.profile;evidence+=p.evidence;unresolved+=p.unresolved;validated.formUnion(p.validatedModules)
        }
        var endpoints=[GenerationProposal]()
        for condition in [0,2] {
            var current=working,proof=evidence,notes=unresolved,modules=validated
            var stageOptions=options;stageOptions.conditionIndex=condition
            if options.modules.contains(.detail) {
                current.parameters.detail.enabled=baseline.parameters.detail.enabled;current.parameters.softening.enabled=baseline.parameters.softening.enabled
                let p=try DetailSolver.solve(measurements:measurements,baseline:current,options:stageOptions,resources:resources,progress:progress)
                current=p.profile;proof+=p.evidence;notes+=p.unresolved;modules.formUnion(p.validatedModules)
            }
            if options.modules.contains(.glow) {
                if condition==0 {
                    current.parameters.glow.enabled=baseline.parameters.glow.enabled;current.parameters.halation.enabled=baseline.parameters.halation.enabled
                    let p=try GlowSolver.solve(measurements:measurements,baseline:current,options:stageOptions,resources:resources,progress:progress)
                    current=p.profile;proof+=p.evidence;notes+=p.unresolved;modules.formUnion(p.validatedModules)
                }else {
                    current.parameters.glow=endpoints[0].profile.parameters.glow;current.parameters.halation=endpoints[0].profile.parameters.halation
                    proof+=endpoints[0].evidence.filter{$0.algorithm == .glow};modules.insert(.glow)
                    notes.append("光晕只在低 ISO 亮源验证；高 ISO 使用相同固定扩散模型，不推断光晕的 ISO 变化")
                }
            }
            if options.modules.contains(.texture) {
                current.parameters.noise.enabled=baseline.parameters.noise.enabled;current.parameters.grain.enabled=baseline.parameters.grain.enabled
                let p=try TextureSolver.solve(measurements:measurements,baseline:current,options:stageOptions,resources:resources,progress:progress)
                current=p.profile;proof+=p.evidence;notes+=p.unresolved;modules.formUnion(p.validatedModules)
            }
            let iso=measurements.frames.first{$0.step.role == .input && $0.step.conditionIndex==condition}?.actualConditions.iso
            endpoints.append(.init(profile:current,evidence:proof,unresolved:notes,resourceDigests:resources.digests,validatedModules:modules,sourceISO:iso))
        }
        progress(.init(stage:"生成拍摄条件响应",completed:0))
        var candidate=try ConditionResponseSolver.solve(proposals:endpoints,captures:captures,baseline:baseline)
        let report=try CombinedValidation.run(proposal:candidate,baseline:baseline,measurements:measurements,resources:resources,progress:progress)
        guard report.passed else {throw GenerationValidationFailure(report:report)}
        try Task.checkCancellation()
        candidate.validationPassed=true;candidate.evidence+=report.rows
        if !candidate.profile.responses.isEmpty {candidate.validatedModules.insert(.conditionResponse)}
        candidate.unresolved.removeAll{$0.contains("中间 ISO 和组合效果尚待")}
        candidate.unresolved.append("仅已选择模块及已拍摄条件通过自动验证；保存前仍需摄影师观察独立实景照片并确认")
        return candidate
    }
    /// Rechecking an edited/restored candidate never optimizes against held-out photos.
    /// These are reused validation observations, not a new independent generalization trial.
    public static func revalidate(candidate:GenerationProposal,captures:CaptureSet,baseline:Profile,options:GenerationOptions,resources:GenerationResources,eligibility:GenerationEligibility,progress:@Sendable(GenerationProgress)->Void = {_ in})async throws->GenerationProposal {
        guard !options.modules.isEmpty,options.modules.isSubset(of:featureModules),requiredAlgorithms(for:options.modules).isSubset(of:eligibility.algorithms),candidate.validatedModules.intersection(featureModules)==options.modules,resources.digests==candidate.resourceDigests else{throw LabError.invalid("候选、所选模块、资源或自检资格不匹配")}
        let measurements=try GenerationPreparation.prepare(captures:captures,resources:resources,modules:options.modules,progress:progress)
        let report=try CombinedValidation.run(proposal:candidate,baseline:baseline,measurements:measurements,resources:resources,progress:progress)
        guard report.passed else{throw GenerationValidationFailure(report:report)}
        try Task.checkCancellation()
        var result=candidate;result.validationPassed=true;result.evidence=report.rows
        result.unresolved.append("当前编辑已在原留出照片上复核；这些重复使用的数据不构成新的独立泛化验证")
        return result
    }
}
