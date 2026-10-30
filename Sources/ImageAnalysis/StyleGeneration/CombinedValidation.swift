import Foundation
import Metal
import ImagingCore

public struct GenerationValidationReport:Sendable {
    public let rows:[AlgorithmCaseResult]
    public var passed:Bool {!rows.isEmpty && rows.allSatisfy{$0.status == .passed && $0.measured.map{$0.isFinite && $0>=0} == true}}
}
/// Re-renders the complete candidate and baseline on held-out originals. Previous
/// proposal flags or single-module residuals never substitute for this check.
public enum CombinedValidation {
    public static func run(proposal:GenerationProposal,baseline:Profile,measurements:MeasurementBundle,resources:GenerationResources,progress:@Sendable(GenerationProgress)->Void = {_ in})throws->GenerationValidationReport {
        try proposal.profile.validate();try baseline.validate()
        let modules=proposal.validatedModules.intersection([.toneColor,.detail,.texture,.glow])
        guard !modules.isEmpty,modules==proposal.validatedModules.subtracting([.conditionResponse]),resources.digests==proposal.resourceDigests,resources.digests==measurements.resourceDigests,
              modules.allSatisfy({m in proposal.evidence.contains{$0.algorithm==m && $0.status == .passed}}),
              Set(measurements.frames.map(\.fileDigest)).count==measurements.frames.count,Set(measurements.frames.map(\.step.id)).count==measurements.frames.count else {throw LabError.measurement("组合验收需要独立照片、匹配资源及完整的单项证据")}
        let expected:[CaptureTarget:Int]=[.composite:54,.flat:72,.light:18]
        let families:Set<CaptureTarget>=Set(modules.map{ $0 == .texture ? .flat:$0 == .glow ? .light:.composite })
        let images=GenerationImages()
        for family in families {
            let set=measurements.frames.filter{$0.step.target==family}
            guard set.count==expected[family] else{throw LabError.measurement("\(family.rawValue)：组合验收照片不足，需要完整未见中档及两端条件")}
            for f in set {
                let s=f.step,last=family == .flat ? 3:2
                guard (family == .light ? [0]:[0,1,2]).contains(s.conditionIndex),[-1.0,0,1].contains(s.exposureEV),(0...last).contains(s.repeatIndex),
                      s.id=="\(s.role.rawValue)-\(family.rawValue)-\(s.conditionIndex)-\(Int(s.exposureEV))-\(s.repeatIndex)",s.purpose == (s.conditionIndex==1 || s.repeatIndex==last ? .validation:.training),
                      CaptureQuality.evaluate(patches:f.patches,conditions:f.actualConditions,step:s).isEmpty else {throw LabError.measurement("组合验证的拍摄质量或固定留出划分无效")}
                // Verify both input and target files, including targets whose measurements were cached.
                _=try images.load(f)
            }
        }
        try validateConditions(measurements.frames.filter{families.contains($0.step.target)},responses:proposal.profile.responses)
        guard let device=MTLCreateSystemDefaultDevice()else{throw LabError.noMetal}
        let renderer=try MetalRenderer(cacheLimitBytes:128*1024*1024);defer{renderer.releaseCaches()}
        let definition=try StyleEvaluator.compile(proposal.profile),baseDefinition=try StyleEvaluator.compile(baseline)
        func style(_ frame:FrameMeasurements,_ candidate:Bool)throws->ResolvedStyle {
            let evaluated=try StyleEvaluator.evaluate(candidate ? definition:baseDefinition,conditions:frame.actualConditions)
            guard evaluated.diagnostics.allSatisfy({$0.status == .applied}) else{throw LabError.measurement("验证照片缺少配置所需拍摄条件")}
            return try evaluated.resolvedStyle()
        }
        var rows=[AlgorithmCaseResult]()
        func row(_ module:AlgorithmID,_ group:String,_ metric:String,_ error:Double,_ previous:Double,_ tolerance:Double,_ slack:Double) {
            let limit=GenerationLimit(caseID:metric,unit:"normalized error",validDomain:"original pixels; fixed held-out group",absoluteTolerance:tolerance,relativeTolerance:0,referenceMagnitude:1)
            let accepted=limit.accepts(error) && previous.isFinite && error<=previous+slack
            rows.append(.init(algorithm:module,caseID:group+"/"+metric,status:accepted ? .passed:.failed,measured:error.isFinite ? error:nil,limit:limit,detail:"\(group) / \(metric)：候选 \(error)，基准 \(previous)，上限 \(tolerance)；\(accepted ? "通过":"退化或超出测量阈值")"))
        }
        let grouped=Dictionary(grouping:measurements.frames.filter{families.contains($0.step.target) && $0.step.target != .flat},by:{$0.step.pairKey})
        let light=modules.contains(.glow) ? try GPULightMeasurement(device:device):nil
        var measuring:AlgorithmID = .glow
        func measureGroup(_ key:String)throws {try autoreleasepool {
            let pair=grouped[key]!
            guard pair.count==2,let a=pair.first(where:{$0.step.role == .input}),let b=pair.first(where:{$0.step.role == .target}) else{throw LabError.measurement("组合验证缺少唯一原图与参考图")}
            // Whole unseen exposure plus repeat holdout; middle ISO is always unseen.
            guard a.step.purpose == .validation || a.step.exposureEV == (a.step.target == .light ? -1:1) else{return}
            let input=try images.load(a),target=try images.load(b),candidate=try style(a,true),prior=try style(a,false)
            if a.step.target == .light,let light {
                measuring = .glow
                let truth=try renderer.renderLightSignature(target,style:ResolvedStyle(profile:.standard),resources:.init(),measurement:light)
                let output=try renderer.renderLightSignature(input,style:candidate,resources:resources.rendering,measurement:light)
                let original=try renderer.renderLightSignature(input,style:prior,resources:resources.rendering,measurement:light)
                try truth.validate()
                row(.glow,key,"RGB 扩散",output.error(to:truth),original.error(to:truth),0.01,0.0001)
                row(.glow,key,"亮源裁切",output.clipped,original.clipped,0,0)
            }
            if a.step.target == .composite {
                guard let pose=a.pose,let targetPose=b.pose else{throw LabError.measurement("组合板缺少原生像素定位")}
                if modules.contains(.toneColor) {
                    measuring = .toneColor
                    let regions=TargetLayout.composite.regions.filter{$0.kind == .gray || $0.kind == .color}
                    let truth=try renderer.renderPatchStatistics(target,style:ResolvedStyle(profile:.standard),transform:targetPose,regions:regions)
                    let output=try renderer.renderPatchStatistics(input,style:candidate,resources:resources.rendering,transform:pose,regions:regions)
                    let original=try renderer.renderPatchStatistics(input,style:prior,resources:resources.rendering,transform:pose,regions:regions)
                    for i in regions.indices {
                        func error(_ p:PatchMeasurement)->Double{zip(p.mean,truth[i].mean).map{abs($0-$1)}.max() ?? .infinity}
                        row(.toneColor,key,regions[i].id,error(output[i]),error(original[i]),0.015,0.0001)
                    }
                }
                if modules.contains(.detail) {
                    measuring = .detail
                    guard min(a.width,a.height)>=2048,min(b.width,b.height)>=2048,abs(log2(try GenerationImages.relativeScale(input:a,target:b)))<0.02 else{throw LabError.measurement("组合验证的细节像素尺度不匹配")}
                    func features(_ img:ImageFrame,_ f:FrameMeasurements,_ s:ResolvedStyle,_ rendered:Bool)throws->([Double],Double,[Double]) {
                        let r=rendered ? resources.rendering:.init()
                        let edge=try renderer.renderFeatureStatistics(img,style:s,resources:r,request:.init(input:img.descriptor),region:GenerationImages.region("edge",frame:f),kind:.edge)
                        let detail=try renderer.renderFeatureStatistics(img,style:s,resources:r,request:.init(input:img.descriptor),region:GenerationImages.region("detail",frame:f),kind:.texture)
                        guard let e=edge.curves["edge"],let rms=detail.metrics["rms"],let psd=detail.curves["psd"],e.count==128,psd.count==33 else{throw LabError.measurement("缺少组合细节指标")}
                        return(e,rms,[psd[1...5].reduce(0,+),psd[6...15].reduce(0,+),psd[16...32].reduce(0,+)])
                    }
                    let truth=try features(target,b,ResolvedStyle(profile:.standard),false),output=try features(input,a,candidate,true),original=try features(input,a,prior,true)
                    func edgeError(_ value:[Double])->Double{sqrt(zip(value,truth.0).map{pow($0-$1,2)}.reduce(0,+)/128)}
                    row(.detail,key,"斜边",edgeError(output.0),edgeError(original.0),0.01,0.0001)
                    row(.detail,key,"细节对比",abs(output.1/truth.1-1),abs(original.1/truth.1-1),0.05,0.001)
                    for i in 0..<3 where truth.2[i]>1e-10 {row(.detail,key,"频段\(i+1)",abs(output.2[i]/truth.2[i]-1),abs(original.2[i]/truth.2[i]-1),0.05,0.001)}
                }
            }
            progress(.init(stage:"组合验证：\(key)",completed:rows.count))
        }}
        for key in grouped.keys.sorted() {
            do {try measureGroup(key)}
            catch LabError.measurement(let reason) {
                let limit=GenerationLimits.cases(for:measuring).first!
                rows.append(.init(algorithm:measuring,caseID:key+"/无法测量",status:.failed,measured:nil,limit:limit,detail:key+"："+reason))
            }
        }
        if modules.contains(.texture) {
            let temporal=try GPUTemporalTexture(device:device)
            for condition in 0...2 {for ev in [-1.0,0,1] {try autoreleasepool {
                let set=measurements.frames.filter{$0.step.target == .flat && $0.step.conditionIndex==condition && $0.step.exposureEV==ev}
                let input=set.filter{$0.step.role == .input}.sorted{$0.step.repeatIndex<$1.step.repeatIndex},target=set.filter{$0.step.role == .target}.sorted{$0.step.repeatIndex<$1.step.repeatIndex}
                guard input.count==4,target.count==4 else{throw LabError.measurement("平场独立验证组不完整")}
                func stats(_ set:[FrameMeasurements],_ candidate:Bool?,_ offset:UInt32)throws->TemporalTexture {
                    var textures=[MTLTexture]()
                    for (i,f) in set.enumerated() {let s=try candidate.map{try style(f,$0)} ?? ResolvedStyle(profile:.standard)
                        textures.append(try renderer.renderGenerationCrop(images.load(f),style:s,resources:candidate==nil ? .init():resources.rendering,seed:99173+UInt32(i)*7919+offset))}
                    return try temporal.measure(textures)
                }
                let truth=try stats(target,nil,0),output=try stats(input,true,17),original=try stats(input,false,17),key="flat-\(condition)-\(ev)"
                for (name,t,o,b) in [("独立重复",truth.validation,output.validation,original.validation),("前两重复",truth.training,output.training,original.training)] {
                    let denominator=max(1e-7,t.varianceY)
                    row(.texture,key,name+"/方差",abs(o.varianceY-t.varianceY)/denominator,abs(b.varianceY-t.varianceY)/denominator,0.10,0.01)
                    for (channel,tv,ov,bv) in [("Cb",t.varianceCb,o.varianceCb,b.varianceCb),("Cr",t.varianceCr,o.varianceCr,b.varianceCr)] {
                        let scale=max(5e-7,tv);row(.texture,key,name+"/"+channel,abs(ov-tv)/scale,abs(bv-tv)/scale,0.20,0.01)
                    }
                    for i in 0..<3 where t.varianceY>1e-7 {row(.texture,key,name+"/频段\(i+1)",abs(o.varianceY*o.bands[i]-t.varianceY*t.bands[i])/denominator,abs(b.varianceY*b.bands[i]-t.varianceY*t.bands[i])/denominator,0.15,0.01)}
                }
                row(.texture,key,"平均亮度",abs(output.mean-truth.mean),abs(original.mean-truth.mean),0.015,0.0001)
                progress(.init(stage:"组合验证：\(key)",completed:rows.count))
            }}}
        }
        guard modules.allSatisfy({m in rows.contains{$0.algorithm==m}}) else{throw LabError.measurement("组合验证遗漏已选择模块")}
        return .init(rows:rows)
    }
    static func validateConditions(_ frames:[FrameMeasurements],responses:[ConditionBinding])throws {
        var levels=[CaptureRole:[Int:Double]]()
        for role in CaptureRole.allCases {
            let all=frames.filter{$0.step.role==role}
            var axis=[Int:Double]()
            for index in Set(all.map{$0.step.conditionIndex}) {
                let set=all.filter{$0.step.conditionIndex==index}
                guard let iso=set.first?.actualConditions.iso,iso.isFinite,iso>0,
                      set.allSatisfy({f in guard let value=f.actualConditions.iso else{return false};return value.isFinite && value>0 && abs(log2(value/iso))<=0.08}) else {throw LabError.measurement("同一条件的实际 ISO 不一致，不能使用组名代替拍摄条件")}
                axis[index]=iso
            }
            if all.contains(where:{$0.step.target != .light}) {
                guard let low=axis[0],let mid=axis[1],let high=axis[2],log2(mid/low)>0.16,log2(high/mid)>0.16 else {throw LabError.measurement("需要实际不同且递增的低、中、高 ISO；中间条件不能用重复低 ISO 照片替代")}
            }
            levels[role]=axis
        }
        for response in responses {
            guard response.axis == .iso,let low=levels[.input]?[0],let high=levels[.input]?[2],
                  let first=response.curve.knots.first?.x,let last=response.curve.knots.last?.x,
                  abs(log2(first/low))<=0.08,abs(log2(last/high))<=0.08 else {throw LabError.measurement("响应横轴必须匹配实拍原图 ISO 的两个端点；其他条件轴未取得本协议验证")}
        }
    }

}
