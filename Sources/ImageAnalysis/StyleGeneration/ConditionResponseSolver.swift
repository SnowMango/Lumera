import Foundation
import ImagingCore

/// Builds the least flexible response supported by two measured endpoint conditions.
/// It never qualifies the unobserved middle condition; CombinedValidation must do that.
public enum ConditionResponseSolver {
    public static func solve(proposals:[GenerationProposal],captures:CaptureSet,baseline:Profile) throws -> GenerationProposal {
        try baseline.validate()
        guard proposals.count==2,baseline.responses.isEmpty,captures.issues.isEmpty,
              captures.protocolVersion=="capture-draft-1" else {throw LabError.invalid("条件响应需要两个合格端点、当前采集协议和无响应曲线的基准")}
        let sorted=proposals.sorted{($0.sourceISO ?? 0)<($1.sourceISO ?? 0)}
        let lo=sorted[0],hi=sorted[1]
        guard let low=lo.sourceISO,let high=hi.sourceISO,low.isFinite,high.isFinite,low>0,high>low,
              !lo.validatedModules.isEmpty,lo.validatedModules==hi.validatedModules,
              lo.resourceDigests==hi.resourceDigests else {throw LabError.invalid("端点 ISO、合格模块或 LUT 资源不一致")}
        for proposal in sorted {
            try proposal.profile.validate()
            guard proposal.profile.responses.isEmpty,
                  proposal.profile.temporalPolicy==baseline.temporalPolicy,
                  proposal.validatedModules.isSubset(of:[.toneColor,.detail,.texture,.glow]),
                  proposal.validatedModules.allSatisfy({id in proposal.evidence.contains{$0.algorithm==id && $0.status == .passed && $0.measured.map{$0.isFinite} == true}}),
                  proposal.evidence.allSatisfy({$0.status == .passed && $0.measured.map{$0.isFinite && $0>=0} == true}) else {
                throw LabError.invalid("端点尚未完成模块验证，或包含未支持的响应")
            }
        }
        let records=captures.records.filter{$0.step.role == .input && $0.step.target == .composite}
        guard records.count==27,Set(records.map(\.step.id)).count==27,Set(records.map(\.fileDigest)).count==27 else {throw LabError.invalid("原图需包含三档 ISO 的完整独立综合板照片")}
        var levels=[Double]()
        for index in 0...2 {
            let group=records.filter{$0.step.conditionIndex==index}
            guard group.count==9,let iso=group.first?.actualConditions.iso,iso.isFinite,iso>0,
                  Set(group.map{"\($0.step.exposureEV)/\($0.step.repeatIndex)"}).count==9,
                  group.allSatisfy({r in
                      guard let i=r.actualConditions.iso,let t=r.actualConditions.exposureDurationSeconds else{return false}
                      return r.issues.isEmpty && i.isFinite && t.isFinite && i>0 && t>0 && abs(log2(i/iso))<=0.08 && abs(log2(i/r.step.expectedISO))<=0.08 && abs(log2(t/r.step.expectedExposureSeconds))<=0.15 && [-1.0,0,1].contains(r.step.exposureEV) && (0...2).contains(r.step.repeatIndex) && r.step.purpose == (index==1 || r.step.repeatIndex==2 ? .validation:.training)
                  }) else {throw LabError.invalid("原图中间验证条件或曝光/重复照片不完整")}
            levels.append(iso)
        }
        guard levels[0]<levels[1],levels[1]<levels[2],abs(log2(low/levels[0]))<=0.08,abs(log2(high/levels[2]))<=0.08 else {throw LabError.invalid("响应轴必须来自原图的低、中、高 ISO，不能使用参考相机 ISO")}
        var result=lo.profile
        let a=lo.profile.parameters,b=hi.profile.parameters
        let fixedA=a
        var fixedB=b
        func binding(_ target:ResponseTarget,_ start:Double,_ end:Double,_ operation:ResponseOperation = .replace) {
            guard start != end else{return}
            result.responses.append(.init(target:target,axis:.iso,operation:operation,curve:.init(knots:[.init(x:low,y:start),.init(x:high,y:end)])))
        }
        if lo.validatedModules.contains(.detail) {
            guard a.detail.enabled==b.detail.enabled,a.softening.enabled==b.softening.enabled else {throw LabError.invalid("细节端点启用状态不一致")}
            binding(.fineGain,a.detail.fineGain,b.detail.fineGain)
            binding(.softeningAmount,a.softening.amount,b.softening.amount)
            fixedB.detail.fineGain=fixedA.detail.fineGain;fixedB.softening.amount=fixedA.softening.amount
        }
        if lo.validatedModules.contains(.texture) {
            guard a.noise.enabled==b.noise.enabled,a.grain.enabled==b.grain.enabled,!(a.noise.enabled && a.grain.enabled) else {throw LabError.invalid("条件响应只支持一种随机质感模型且端点启用状态一致")}
            if a.noise.enabled {
                let ratio=try proportional(a.noise.curve,gain:a.noise.gain,b.noise.curve,gain:b.noise.gain)
                if ratio>=1 {result.parameters.noise=b.noise;binding(.noiseGain,ratio==0 ? 0:1/ratio,1,.multiply)}
                else {binding(.noiseGain,1,ratio,.multiply)}
                fixedB.noise.curve=fixedA.noise.curve;fixedB.noise.gain=fixedA.noise.gain
            }
            if a.grain.enabled {
                let ratio=try proportional(a.grain.luminanceCurve,gain:a.grain.amount,b.grain.luminanceCurve,gain:b.grain.amount)
                if ratio>=1 {result.parameters.grain=b.grain;binding(.grainAmount,b.grain.amount/ratio,b.grain.amount)}
                else {binding(.grainAmount,a.grain.amount,a.grain.amount*ratio)}
                fixedB.grain.luminanceCurve=fixedA.grain.luminanceCurve;fixedB.grain.amount=fixedA.grain.amount
            }
        }
        guard fixedA==fixedB else {throw LabError.invalid("端点还包含色调、颜色、空间尺度或频谱变化，不能由单条强度响应表达")}
        // Keep the caller's identity. A candidate never overwrites its source style automatically.
        result.id=baseline.id;result.name=baseline.name;result.description=baseline.description
        try result.validate()
        return .init(profile:result,evidence:lo.evidence+hi.evidence,
                     unresolved:Array(Set(lo.unresolved+hi.unresolved)).sorted()+["中间 ISO 和组合效果尚待独立照片验证", "ISO 与快门在本采集协议中共变；此响应仅描述已拍摄条件，不代表独立快门规律"],
                     resourceDigests:lo.resourceDigests,validatedModules:lo.validatedModules)
    }
    /// Dense points plus all declared controls: amplitude changes within 2% envelope uncertainty; actual held-out images must validate the approximation.
    private static func proportional(_ a:ResponseCurve,gain ga:Double,_ b:ResponseCurve,gain gb:Double)throws->Double {
        let xs=Set((0...1024).map{Double($0)/1024}+a.knots.map(\.x)+b.knots.map(\.x)).sorted()
        let av=xs.map{a.value(at:$0)*ga},bv=xs.map{b.value(at:$0)*gb}
        guard let peak=av.indices.max(by:{av[$0]<av[$1]}),av[peak]>1e-10 else {throw LabError.invalid("零强度端点无法确定亮度响应形状")}
        let ratio=bv[peak]/av[peak]
        guard ratio.isFinite,ratio>0,zip(av,bv).allSatisfy({abs($0*ratio-$1)<=max(1e-7,0.02*max($1,$0*ratio))}) else {throw LabError.invalid("噪点或颗粒亮度响应形状变化，单一 ISO 强度曲线不足以表达")}
        return ratio
    }
}
