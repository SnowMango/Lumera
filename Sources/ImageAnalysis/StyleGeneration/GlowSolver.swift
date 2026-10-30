import Foundation
import Metal
import ImagingCore

/// Fixed-scale neutral and tinted diffusion, estimated together from RGB rings.
/// Radius, threshold, tint and source geometry are not free variables.
public enum GlowSolver {
    public static func solve(measurements:MeasurementBundle,baseline:Profile,options:GenerationOptions,resources:GenerationResources,progress:@Sendable(GenerationProgress)->Void = {_ in})throws->GenerationProposal {
        try baseline.validate()
        guard options.modules.contains(.glow),baseline.responses.isEmpty,resources.digests==measurements.resourceDigests,
              !baseline.parameters.noise.isActive,!baseline.parameters.grain.isActive else {throw LabError.measurement("亮源扩散需要固定基线与资源，先完成确定性明暗/细节，不叠加随机质感")}
        let frames=measurements.frames.filter{$0.step.target == .light}
        guard frames.count==18,Set(frames.map(\.fileDigest)).count==18,Set(frames.map(\.step.id)).count==18 else {throw LabError.measurement("需要两设备三档曝光、每档三张不同的亮源照片")}
        for f in frames {
            let s=f.step
            guard s.conditionIndex==0,[-1.0,0,1].contains(s.exposureEV),(0...2).contains(s.repeatIndex),s.purpose == (s.repeatIndex==2 ? .validation:.training),
                  s.id=="\(s.role.rawValue)-light-0-\(Int(s.exposureEV))-\(s.repeatIndex)",CaptureQuality.evaluate(patches:f.patches,conditions:f.actualConditions,step:s).isEmpty else {throw LabError.measurement("亮源照片步骤、拍摄参数或采样质量不合格")}
        }
        guard let device=MTLCreateSystemDefaultDevice()else{throw LabError.noMetal}
        let renderer=try MetalRenderer(cacheLimitBytes:128*1024*1024),measurement=try GPULightMeasurement(device:device),images=GenerationImages();defer{renderer.releaseCaches()}
        let groups=Dictionary(grouping:frames,by:{$0.step.pairKey})
        var inputs=[FrameMeasurements](),targets=[LightSignature](),training=[Bool](),baseSignatures=[LightSignature]()
        var base=baseline;base.parameters.glow.enabled=false;base.parameters.halation.enabled=false
        for key in groups.keys.sorted() {
            let pair=groups[key]!
            guard pair.count==2,let a=pair.first(where:{$0.step.role == .input}),let b=pair.first(where:{$0.step.role == .target}),a.width==b.width,a.height==b.height else {throw LabError.measurement("亮源照片需一一对应且使用相同成像像素尺度")}
            let source=try autoreleasepool{try renderer.renderLightSignature(images.load(a),style:ResolvedStyle(profile:base),resources:resources.rendering,measurement:measurement)}
            let target=try autoreleasepool{try renderer.renderLightSignature(images.load(b),style:ResolvedStyle(profile:.standard),resources:.init(),measurement:measurement)}
            try source.validate();try target.validate()
            guard abs(source.coreRadius-target.coreRadius)<1.25,abs(source.centerX-target.centerX)<1,abs(source.centerY-target.centerY)<1,abs(source.peak-target.peak)<0.12 else {throw LabError.measurement("亮源中心、尺寸或亮度差异过大；不能把光源变化解释为镜头扩散")}
            let actualBaseline=try autoreleasepool{try renderer.renderLightSignature(images.load(a),style:ResolvedStyle(profile:baseline),resources:resources.rendering,measurement:measurement)}
            inputs.append(a);targets.append(target);baseSignatures.append(actualBaseline)
            training.append(a.step.repeatIndex<2 && a.step.exposureEV != -1)
        }
        var evaluations=0,cache=[String:[LightSignature]]()
        func configured(_ x:Double,_ y:Double)->Profile {
            var p=base;p.parameters.glow.enabled=true;p.parameters.glow.amount=x;p.parameters.halation.enabled=true;p.parameters.halation.amount=y;return p
        }
        func signatures(_ x:Double,_ y:Double)throws->[LightSignature] {
            let key="\(x)/\(y)";if let found=cache[key]{return found}
            var result=[LightSignature]()
            for i in inputs.indices where training[i] {
                result.append(try autoreleasepool{try renderer.renderLightSignature(images.load(inputs[i]),style:ResolvedStyle(profile:configured(x,y)),resources:resources.rendering,measurement:measurement)})
            }
            evaluations+=1;progress(.init(stage:"亮源扩散：RGB 联合候选",completed:evaluations))
            if cache.count>=64 {cache.removeAll(keepingCapacity:true)};cache[key]=result;return result
        }
        func residual(_ x:Double,_ y:Double)throws->[Double] {
            let output=try signatures(x,y),indices=inputs.indices.filter{training[$0]}
            return zip(output,indices).flatMap{s,i in zip(s.rgb,targets[i].rgb).map{($0-$1)/max(0.05,targets[i].peak-targets[i].background)}}
        }
        func score(_ r:[Double])->Double{r.reduce(0){$0+$1*$1}/Double(r.count)}
        var x=0.0,y=0.0,error=try score(residual(0,0))
        for _ in 0..<12 {
            let r=try residual(x,y),dx=x<0.75 ? 0.03:-0.03,dy=y<0.75 ? 0.03:-0.03
            let a=zip(try residual(x+dx,y),r).map{($0-$1)/dx},b=zip(try residual(x,y+dy),r).map{($0-$1)/dy}
            let aa=a.reduce(0){$0+$1*$1},bb=b.reduce(0){$0+$1*$1},ab=zip(a,b).reduce(0){$0+$1.0*$1.1}
            guard aa>1e-6,bb>1e-6,abs(ab)/sqrt(aa*bb)<0.995 else {throw LabError.measurement("亮源未充分触发扩散或两种扩散不可区分；不生成不可靠参数")}
            let delta=try GenerationMath.solve([[aa,ab],[ab,bb]],[-zip(a,r).reduce(0){$0+$1.0*$1.1},-zip(b,r).reduce(0){$0+$1.0*$1.1}])
            let before=error
            for factor in [1.0,0.5,0.25,0.1] {
                let nx=min(0.8,max(0,x+delta[0]*factor)),ny=min(0.8,max(0,y+delta[1]*factor)),e=try score(residual(nx,ny))
                if e<error {x=nx;y=ny;error=e;break}
            }
            if error>=before-1e-12 {break}
        }
        let candidate=configured(x,y),limit=GenerationLimits.cases(for:.glow).first{$0.caseID=="radialResponse"}!
        var evidence=[AlgorithmCaseResult]()
        for i in inputs.indices {
            let output=try autoreleasepool{try renderer.renderLightSignature(images.load(inputs[i]),style:ResolvedStyle(profile:candidate),resources:resources.rendering,measurement:measurement)}
            let error=output.error(to:targets[i]),prior=baseSignatures[i].error(to:targets[i])
            guard output.clipped==0,limit.accepts(error),error<=prior+0.0001 else {throw LabError.measurement("\(inputs[i].step.pairKey)：RGB 扩散验证失败或比基准退化")}
            evidence.append(.init(algorithm:.glow,caseID:inputs[i].step.pairKey,status:.passed,measured:error,limit:limit,detail:training[i] ? "训练 RGB 环形分布":"未见低曝光/重复帧 RGB 验证"))
        }
        return .init(profile:candidate,evidence:evidence,unresolved:["固定光晕尺度、门槛和染色；不代表真实镜头物理模型","光源孔径、距离与相机焦段必须按采集说明固定；仅凭照片不能证明这些物理条件相同"],resourceDigests:resources.digests,validatedModules:[.glow],sourceISO:inputs.first?.actualConditions.iso)
    }
}
