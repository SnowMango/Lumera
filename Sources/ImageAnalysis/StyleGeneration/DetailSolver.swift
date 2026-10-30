import Foundation
import ImagingCore

/// Joint, restricted two-parameter model. Spatial radii are fixed by the baseline;
/// broad-band gain and bounded edge sharpening are not independently released to cancel softness.
public enum DetailSolver {
    public static func solve(measurements:MeasurementBundle,baseline:Profile,options:GenerationOptions,resources:GenerationResources,progress:@Sendable(GenerationProgress)->Void = {_ in}) throws ->GenerationProposal {
        try baseline.validate();try Task.checkCancellation()
        guard options.modules.contains(.detail),resources.digests==measurements.resourceDigests,
              !baseline.parameters.noise.isActive,!baseline.parameters.grain.isActive,!baseline.parameters.glow.isActive,!baseline.parameters.halation.isActive,!baseline.parameters.vignette.isActive,
              baseline.parameters.detail.midGain==1,baseline.parameters.detail.sharpenAmount==0,baseline.responses.isEmpty else {throw LabError.measurement("联合细节模型固定中频/额外锐化与空间尺度；当前基线超出已验收范围")}
        let pairs=try ModuleCapturePair.composite(measurements,condition:options.conditionIndex)
        guard pairs.allSatisfy({min($0.input.width,$0.input.height)>=2048 && min($0.target.width,$0.target.height)>=2048}) else {throw LabError.measurement("联合细节需要短边至少 2048 像素的照片；低分辨率下柔化与细节响应可能无法分开")}
        let renderer=try MetalRenderer(cacheLimitBytes:128*1024*1024),images=GenerationImages();defer{renderer.releaseCaches()}
        var evaluations=0,cache=[String:([Double],Double,[Double])]()
        let started=ProcessInfo.processInfo.systemUptime
        func analysisProfile(_ fine:Double,_ softness:Double)->Profile {
            var p=baseline;p.responses=[]
            p.parameters.detail.enabled=true;p.parameters.detail.fineGain=fine
            p.parameters.softening.enabled=true;p.parameters.softening.amount=softness
            p.parameters.noise.enabled=false;p.parameters.grain.enabled=false;p.parameters.glow.enabled=false;p.parameters.halation.enabled=false;p.parameters.vignette.enabled=false
            return p
        }
        func bands(_ psd:[Double])->[Double] {[psd[1...5].reduce(0,+),psd[6...15].reduce(0,+),psd[16...32].reduce(0,+)]}
        func readTarget(_ pair:ModuleCapturePair)throws->([Double],Double,[Double]) {
            guard let edge=pair.target.curves["edge"],edge.count==128,edge.allSatisfy(\.isFinite),
                  let rms=pair.target.metrics["detailRMS"],rms.isFinite,rms>0.005,
                  let psd=pair.target.curves["detailPSD"],psd.count==33,psd.allSatisfy({$0.isFinite && $0>=0}),
                  let mtf=pair.target.metrics["mtf50"],mtf.isFinite,mtf>0,mtf<=0.5,
                  let original=pair.input.metrics["mtf50"],original.isFinite,original>0.04,
                  let inputEdge=pair.input.curves["edge"],inputEdge.count==128,inputEdge.allSatisfy(\.isFinite),
                  (pair.target.metrics["contrast"] ?? 0).isFinite,(pair.target.metrics["contrast"] ?? 0)>0.05 else {throw LabError.measurement("缺少有效的斜边与细节测量，或打印图案已无法分辨")}
            let scale=try GenerationImages.relativeScale(input:pair.input,target:pair.target)
            guard abs(log2(scale))<0.02 else {throw LabError.measurement("联合细节频谱需要一致的成像像素尺度，请调整构图距离或输出尺寸后重拍")}
            guard mtf/scale<=original*1.5 else {throw LabError.measurement("原图已明显更软，当前受限锐化无法恢复目标信息")}
            let aligned=(0..<128).map{i ->Double in
                let t=min(127,max(0,64+(Double(i)-64)/scale)),low=Int(floor(t)),high=min(127,low+1)
                return edge[low]+(edge[high]-edge[low])*(t-Double(low))
            }
            return (aligned,rms,bands(psd))
        }
        let targets=try pairs.map(readTarget)
        func measure(_ pair:ModuleCapturePair,_ p:Profile)throws->([Double],Double,[Double]) {
            let key=pair.input.fileDigest+"/"+(try p.effectDigest())+"/"+Digest.data(try JSON.encode(pair.input.pose))
            if let value=cache[key] {return value}
            return try autoreleasepool {
                let image=try images.load(pair.input),style=try ResolvedStyle(profile:p),request=RenderRequest(input:image.descriptor)
                let edge=try renderer.renderFeatureStatistics(image,style:style,resources:resources.rendering,request:request,region:GenerationImages.region("edge",frame:pair.input),kind:.edge)
                let pattern=try renderer.renderFeatureStatistics(image,style:style,resources:resources.rendering,request:request,region:GenerationImages.region("detail",frame:pair.input),kind:.texture)
                guard let curve=edge.curves["edge"],let rms=pattern.metrics["rms"],let psd=pattern.curves["psd"] else {throw LabError.measurement("GPU 未返回联合细节指标")}
                let value=(curve,rms,bands(psd));if cache.count>=160 {cache.removeAll(keepingCapacity:true)};cache[key]=value;return value
            }
        }
        func residual(_ fine:Double,_ soft:Double)throws->[Double] {
            try Task.checkCancellation();evaluations+=1
            progress(.init(stage:"联合细节：已评估候选 \(evaluations)",completed:evaluations,elapsedSeconds:ProcessInfo.processInfo.systemUptime-started))
            let p=analysisProfile(fine,soft);var values=[Double]()
            for i in pairs.indices where pairs[i].training {
                let output=try measure(pairs[i],p),target=targets[i]
                values += zip(output.0,target.0).map(-)
                values.append((output.1/target.1-1)*sqrt(128)*0.1)
                for j in 0..<3 where target.2[j]>1e-6 {
                    values.append((output.2[j]/target.2[j]-1)*sqrt(128)*0.1)
                }
            }
            return values
        }
        func score(_ r:[Double])->Double {r.reduce(0){$0+$1*$1}/Double(r.count)}
        var best=(fine:1.0,soft:0.0,error:Double.infinity)
        for fine in [0.7,1.0,1.3] {for soft in [0.0,0.4,0.8] {let error=try score(residual(fine,soft));if error<best.error {best=(fine,soft,error)}}}
        // Solve the coupled local step: axis-only search stalls in the narrow
        // softness/detail valley even when the two responses are identifiable.
        for _ in 0..<16 {
            let r=try residual(best.fine,best.soft)
            let fStep=best.fine<1.26 ? 0.03:-0.03,sStep=best.soft<0.76 ? 0.03:-0.03
            let f=zip(try residual(best.fine+fStep,best.soft),r).map{($0-$1)/fStep}
            let s=zip(try residual(best.fine,best.soft+sStep),r).map{($0-$1)/sStep}
            let ff=f.reduce(0){$0+$1*$1},ss=s.reduce(0){$0+$1*$1},fs=zip(f,s).reduce(0){$0+$1.0*$1.1}
            guard let delta=try? GenerationMath.solve([[ff,fs],[fs,ss]],[-zip(f,r).reduce(0){$0+$1.0*$1.1},-zip(s,r).reduce(0){$0+$1.0*$1.1}]) else {break}
            let before=best.error
            for factor in [1.0,0.5,0.25,0.1] {
                let fine=min(1.3,max(0.7,best.fine+factor*delta[0])),soft=min(0.8,max(0,best.soft+factor*delta[1]))
                let error=try score(residual(fine,soft));if error<best.error {best=(fine,soft,error);break}
            }
            if best.error>=before-1e-12 {break}
        }
        for step in [0.2,0.1,0.05,0.025,0.0125,0.00625] {
            for _ in 0..<4 {
                let before=best.error
                for axis in 0..<2 {for sign in [-1.0,1] {
                    let fine=min(1.3,max(0.7,best.fine+(axis==0 ? sign*step:0))),soft=min(0.8,max(0,best.soft+(axis==1 ? sign*step:0)))
                    let error=try score(residual(fine,soft));if error<best.error {best=(fine,soft,error)}
                }}
                if best.error>=before-1e-12 {break}
            }
        }
        let center=try residual(best.fine,best.soft)
        let fStep=best.fine<1.25 ? 0.04:-0.04,sStep=best.soft<0.75 ? 0.04:-0.04
        let df=zip(try residual(best.fine+fStep,best.soft),center).map{($0-$1)/fStep}
        let ds=zip(try residual(best.fine,best.soft+sStep),center).map{($0-$1)/sStep}
        let ff=df.reduce(0){$0+$1*$1},ss=ds.reduce(0){$0+$1*$1},fs=zip(df,ds).reduce(0){$0+$1.0*$1.1}
        guard ff>1e-6,ss>1e-6,abs(fs)/sqrt(ff*ss)<0.995 else {throw LabError.measurement("细节与柔化响应过于相似，当前素材无法稳定区分；保留原参数")}
        var rows=[AlgorithmCaseResult]()
        let limit=GenerationLimits.cases(for:.detail).first{$0.caseID=="edgeResponse"}!
        let candidate=analysisProfile(best.fine,best.soft)
        let baselineForComparison=analysisProfile(baseline.parameters.detail.enabled ? baseline.parameters.detail.fineGain:1,baseline.parameters.softening.enabled ? baseline.parameters.softening.amount:0)
        for i in pairs.indices where !pairs[i].training {
            let output=try measure(pairs[i],candidate),base=try measure(pairs[i],baselineForComparison),target=targets[i]
            let error=sqrt(zip(output.0,target.0).reduce(0){$0+pow($1.0-$1.1,2)}/128),patternError=abs(output.1/target.1-1)
            let baseError=sqrt(zip(base.0,target.0).reduce(0){$0+pow($1.0-$1.1,2)}/128),basePattern=abs(base.1/target.1-1)
            for j in 0..<3 where target.2[j]>1e-6 {
                let difference=abs(output.2[j]/target.2[j]-1),baselineDifference=abs(base.2[j]/target.2[j]-1)
                guard difference<=0.05,difference<=baselineDifference+0.001 else {throw LabError.measurement("独立细节频段验证失败，保留原参数")}
            }
            guard limit.accepts(error),patternError<=0.05,error<=baseError+0.0001,patternError<=basePattern+0.001 else {throw LabError.measurement("\(pairs[i].input.step.pairKey)：独立斜边或细节图案验证失败，保留原参数")}
            rows.append(.init(algorithm:.detail,caseID:pairs[i].input.step.pairKey,status:.passed,measured:error,limit:limit,detail:"斜边 RMSE \(error)，细节相对差 \(patternError)；未见 +1 EV 与重复帧"))
        }
        var result=baseline;result.parameters.detail.enabled=true;result.parameters.detail.fineGain=best.fine;result.parameters.softening.enabled=true;result.parameters.softening.amount=best.soft
        return .init(profile:result,evidence:rows,unresolved:["联合建议仅调整细节强度与柔化强度；空间尺度固定。打印边缘限制、额外锐化及局部镜头变化不由此反演。"],resourceDigests:resources.digests,validatedModules:[.detail],sourceISO:pairs.first?.input.actualConditions.iso)
    }
}
