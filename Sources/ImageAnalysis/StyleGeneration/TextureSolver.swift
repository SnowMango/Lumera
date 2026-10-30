import Foundation
import Metal
import ImagingCore

struct TextureEstimate {var lowSigma:Double,highSigma:Double,maximumError:Double}
/// Adds only the observable random variance. Spatial/chroma shape stays fixed and
/// must match independently; fixed paper texture is never converted into grain.
public enum TextureSolver {
    static func estimate(groups:[TextureCondition],model:GenerationModel)throws->TextureEstimate {
        guard groups.count==3,Set(groups.map(\.exposureEV))==Set([-1.0,0,1]) else {throw LabError.measurement("随机质感需要三档平场曝光，不能用重复帧替代未见曝光")}
        let groups=groups.sorted{$0.exposureEV<$1.exposureEV}
        for g in groups {
            for t in [g.input,g.target,g.unit] {
                guard t.mean.isFinite,(0.08...0.92).contains(t.mean),t.lagSpread.isFinite,t.lagSpread<0.2 else {throw LabError.measurement("平场曝光或时序统计无效")}
                try t.training.validate();try t.validation.validate()
            }
        }
        guard groups[2].input.mean-groups[0].input.mean>0.12,groups[1].input.mean>groups[0].input.mean,groups[1].input.mean<groups[2].input.mean else {throw LabError.measurement("平场三档亮度覆盖不足，无法确定亮度响应")}
        func amplitude(_ g:TextureCondition)throws->Double {
            let difference=g.target.training.varianceY-g.input.training.varianceY
            guard difference>=(-1e-7),g.unit.training.varianceY>1e-7 else {throw LabError.measurement("原图已有噪声超过目标，增加噪点/颗粒无法还原")}
            let value=0.02*sqrt(max(0,difference)/g.unit.training.varianceY)
            guard value<=0.08 else {throw LabError.measurement("新增质感强度超出已验收范围")};return value
        }
        // Extreme exposure pair trains. The middle exposure is never used to choose the curve.
        let a=try amplitude(groups[0]),b=try amplitude(groups[2]),x0=groups[0].input.mean,x1=groups[2].input.mean
        let slope=(b-a)/(x1-x0),low=a-slope*x0,high=a+slope*(1-x0)
        guard low>=0,high>=0,low<=0.08,high<=0.08 else {throw LabError.measurement("线性质感亮度响应超出有效域；保留原参数，需补充条件或人工调整")}
        var worst=0.0
        for g in groups {
            let sigma=low+(high-low)*g.input.mean,k=pow(sigma/0.02,2)
            for validation in [false,true] {
                let input=validation ? g.input.validation:g.input.training,target=validation ? g.target.validation:g.target.training,unit=validation ? g.unit.validation:g.unit.training
                let predicted=input.varianceY+k*unit.varianceY
                let error=abs(predicted-target.varianceY)/max(1e-7,target.varianceY)
                guard error<=0.10 else {throw LabError.measurement("平场 EV \(g.exposureEV)：独立重复帧/留出曝光的方差差异超过 10%")}
                worst=max(worst,error)
                let baseError=abs(input.varianceY-target.varianceY)/max(1e-7,target.varianceY)
                guard error<=baseError+0.01 else {throw LabError.measurement("随机质感候选比原状退化")}
                for (v,t) in [(input.varianceCb+k*unit.varianceCb,target.varianceCb),(input.varianceCr+k*unit.varianceCr,target.varianceCr)] {
                    guard abs(v-t)<=max(1e-7,t*0.2) else {throw LabError.measurement("目标彩色噪声与固定模型不符，不能仅靠强度匹配")}
                }
                if target.varianceY>1e-7 {
                    for i in 0..<3 {
                        let band=(input.varianceY*input.bands[i]+k*unit.varianceY*unit.bands[i])/max(1e-20,predicted)
                        guard abs(band-target.bands[i])<0.15 else {throw LabError.measurement("目标频谱与当前模型不符，检查压缩、打印网点、空间尺度或降噪；不自动修改半径")}
                    }
                }
            }
        }
        return .init(lowSigma:low,highSigma:high,maximumError:worst)
    }
    static func configured(_ baseline:Profile,model:GenerationModel,low:Double,high:Double)->Profile {
        var p=baseline;p.parameters.noise.enabled=false;p.parameters.grain.enabled=false
        if model == .digital {
            p.parameters.noise.enabled=true;p.parameters.noise.gain=1
            p.parameters.noise.curve = .init(function:.init(family:.linear,start:low,end:high))
        } else {
            p.parameters.grain.enabled=true;p.parameters.grain.amount=0.1
            p.parameters.grain.luminanceCurve = .init(function:.init(family:.linear,start:low/0.1,end:high/0.1))
        }
        return p
    }
    public static func solve(measurements:MeasurementBundle,baseline:Profile,options:GenerationOptions,resources:GenerationResources,progress:@Sendable(GenerationProgress)->Void = {_ in}) throws ->GenerationProposal {
        try baseline.validate()
        guard options.modules.contains(.texture),[0,2].contains(options.conditionIndex),baseline.responses.isEmpty,resources.digests==measurements.resourceDigests else {throw LabError.measurement("随机质感需要固定基线、匹配资源与低/高训练条件")}
        let frames=measurements.frames.filter{$0.step.target == .flat && $0.step.conditionIndex==options.conditionIndex}
        guard frames.count==24,Set(frames.map{$0.step.id}).count==24,Set(frames.map(\.fileDigest)).count==24 else {throw LabError.measurement("需要两设备各三档曝光，每档四张不同的平场重复照片")}
        for f in frames {
            let s=f.step
            guard [-1.0,0,1].contains(s.exposureEV),(0...3).contains(s.repeatIndex),s.purpose == (s.repeatIndex==3 ? .validation:.training),
                  s.id=="\(s.role.rawValue)-flat-\(s.conditionIndex)-\(Int(s.exposureEV))-\(s.repeatIndex)",CaptureQuality.evaluate(patches:f.patches,conditions:f.actualConditions,step:s).isEmpty else {throw LabError.measurement("平场照片步骤、元数据或质量未通过")}
        }
        for role in CaptureRole.allCases {
            let set=frames.filter{$0.step.role==role},isos=set.compactMap{$0.actualConditions.iso}
            guard let first=isos.first,isos.allSatisfy({abs(log2($0/first))<0.08}),Set(set.map{"\($0.width)x\($0.height)"}).count==1 else {throw LabError.measurement("同一条件的重复帧 ISO 或像素尺寸不一致")}
        }
        guard let device=MTLCreateSystemDefaultDevice() else {throw LabError.noMetal}
        let temporal=try GPUTemporalTexture(device:device),renderer=try MetalRenderer(cacheLimitBytes:128*1024*1024),images=GenerationImages();defer{renderer.releaseCaches()}
        var base=baseline;base.parameters.noise.enabled=false;base.parameters.grain.enabled=false
        var unit=configured(base,model:options.model,low:0.02,high:0.02)
        // Per-capture seed variation is explicit; no change to runtime policy required.
        unit.temporalPolicy.noise = .fixed;unit.temporalPolicy.grain = .fixed
        func measure(_ files:[FrameMeasurements],_ profile:Profile,_ useResources:Bool,seedOffset:Int=0)throws->TemporalTexture {
            var crops=[MTLTexture]()
            for (i,f) in files.enumerated() {try autoreleasepool {
                let image=try images.load(f)
                crops.append(try renderer.renderGenerationCrop(image,style:ResolvedStyle(profile:profile),resources:useResources ? resources.rendering:.init(),seed:UInt32(1729+i*997+seedOffset)))
            }}
            return try temporal.measure(crops)
        }
        var groups=[TextureCondition]()
        for ev in [-1.0,0,1] {
            try Task.checkCancellation();progress(.init(stage:"随机质感：平场 EV \(ev)",completed:groups.count,total:3))
            let input=frames.filter{$0.step.role == .input && $0.step.exposureEV==ev}.sorted{$0.step.repeatIndex<$1.step.repeatIndex}
            let target=frames.filter{$0.step.role == .target && $0.step.exposureEV==ev}.sorted{$0.step.repeatIndex<$1.step.repeatIndex}
            guard input.count==4,target.count==4 else {throw LabError.measurement("平场重复组缺失")}
            let inputStats=try measure(input,base,true),targetStats=try measure(target,.standard,false)
            // Same source pixels cancel exactly; independent injected seeds reveal only model variance.
            let unitStats=try measure(Array(repeating:input[0],count:4),unit,true)
            guard abs(inputStats.mean-targetStats.mean)<0.015 else {throw LabError.measurement("平场明暗还未匹配，请先完成色调；不能把曝光差伪装为质感响应")}
            groups.append(.init(exposureEV:ev,input:inputStats,target:targetStats,unit:unitStats))
        }
        let result=try estimate(groups:groups,model:options.model),profile=configured(baseline,model:options.model,low:result.lowSigma,high:result.highSigma)
        var actualWorst=result.maximumError
        // Validate the actual GPU-rendered candidate on all four original repeats,
        // with a fresh seed set. The variance model is not a substitute for this step.
        for g in groups {
            let inputs=frames.filter{$0.step.role == .input && $0.step.exposureEV==g.exposureEV}.sorted{$0.step.repeatIndex<$1.step.repeatIndex}
            let rendered=try measure(inputs,profile,true,seedOffset:21037)
            for (out,target,base) in [(rendered.training,g.target.training,g.input.training),(rendered.validation,g.target.validation,g.input.validation)] {
                let error=abs(out.varianceY-target.varianceY)/max(1e-7,target.varianceY)
                let original=abs(base.varianceY-target.varianceY)/max(1e-7,target.varianceY)
                guard error<=0.10,error<=original+0.01,
                      zip(out.bands,target.bands).allSatisfy({abs($0-$1)<0.15}),
                      abs(out.varianceCb-target.varianceCb)<=max(1e-7,target.varianceCb*0.2),
                      abs(out.varianceCr-target.varianceCr)<=max(1e-7,target.varianceCr*0.2) else {throw LabError.measurement("平场 EV \(g.exposureEV)：实际成片的随机质感未通过留出验证，保留原参数")}
                actualWorst=max(actualWorst,error)
            }
        }
        let limit=GenerationLimits.cases(for:.texture).first{$0.caseID=="variance"}!
        return .init(profile:profile,evidence:[.init(algorithm:.texture,caseID:"held-out-repeats-and-exposure",status:.passed,measured:actualWorst,limit:limit,detail:"独立重复对与未参与选择的中间曝光均验证；固定空间纹理不计入随机强度")],unresolved:["仅建议新增随机质感及线性亮度响应；尺度、彩色比例固定并检查频谱。不能移除原图噪声，也不反演胶片物理过程。"],resourceDigests:resources.digests,validatedModules:[.texture],sourceISO:frames.first{$0.step.role == .input}?.actualConditions.iso)
    }
}
