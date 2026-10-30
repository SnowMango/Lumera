import Foundation
import ImagingCore

enum CombinedDeveloperCheck {
    struct ColorFiles {var folder:URL,bundle:MeasurementBundle;func cleanup(){try? FileManager.default.removeItem(at:folder)}}
    static func colors()throws->ColorFiles {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        do {
            var bundle=try ColorReferenceSamples.make()
            let side=1200,renderer=try MetalRenderer(cacheLimitBytes:128*1024*1024);defer{renderer.releaseCaches()}
            for i in bundle.frames.indices {try autoreleasepool {
                var f=bundle.frames[i]
                var pixels=[Float](repeating:0.4,count:side*side*4)
                for j in stride(from:3,to:pixels.count,by:4){pixels[j]=1}
                for (index,region) in TargetLayout.composite.regions.enumerated() {
                    // Expanded rectangle leaves the measurement ROI strictly inside the patch.
                    let r=region.rect,x0=max(0,Int(r.x*Double(side))-2),x1=min(side,Int((r.x+r.width)*Double(side))+3),y0=max(0,Int(r.y*Double(side))-2),y1=min(side,Int((r.y+r.height)*Double(side))+3)
                    let delta=Double(f.step.repeatIndex+f.step.conditionIndex*3)*0.00002
                    for y in y0..<y1 {for x in x0..<x1 {for c in 0..<3 {pixels[(y*side+x)*4+c]=Float(f.patches[index].mean[c]+delta)}}}
                }
                let image=try ImageFrame(width:side,height:side,pixels:pixels),data=try ImageCodec.encodeReference(image),url=folder.appendingPathComponent(f.step.id+".png");try data.write(to:url)
                let loaded=try ImageCodec.load(url),pose=ProjectiveTransform(coefficients:[Double(side),0,0,0,Double(side),0,0,0,1])
                f.fileDigest=Digest.data(data);f.sourceURL=url;f.width=side;f.height=side;f.pose=pose
                f.patches=try renderer.renderPatchStatistics(loaded,style:ResolvedStyle(profile:.standard),transform:pose,regions:TargetLayout.composite.regions)
                bundle.frames[i]=f
            }}
            return .init(folder:folder,bundle:bundle)
        }catch{try? FileManager.default.removeItem(at:folder);throw error}
    }
    static func run(progress:@Sendable(GenerationProgress)->Void = {_ in})throws->[String:Double] {
        var failures=0.0
        let color=try colors();defer{color.cleanup()}
        let cp=try ToneColorSolver.solve(measurements:color.bundle,baseline:.standard,options:.init(model:.digital,modules:[.toneColor],baseline:.standard),resources:.init())
        if !(try CombinedValidation.run(proposal:cp,baseline:.standard,measurements:color.bundle,resources:.init(),progress:progress)).passed {failures+=1}
        var wrong=cp;wrong.profile.parameters.color.matrix.values[0]+=0.3
        if (try CombinedValidation.run(proposal:wrong,baseline:.standard,measurements:color.bundle,resources:.init(),progress:progress)).passed {failures+=1}
        var changed=color.bundle;changed.frames[0].fileDigest="stale"
        do{_=try CombinedValidation.run(proposal:cp,baseline:.standard,measurements:changed,resources:.init());failures+=1}catch is CancellationError{throw CancellationError()}catch{}
        progress(.init(stage:"准备独立三档细节照片",completed:0))
        let detail=try DetailReferenceSamples.make(allConditions:true);defer{detail.cleanup()}
        let dp=try DetailSolver.solve(measurements:detail.measurements,baseline:.standard,options:.init(model:.digital,modules:[.detail],baseline:.standard),resources:.init(),progress:progress)
        let good=try CombinedValidation.run(proposal:dp,baseline:.standard,measurements:detail.measurements,resources:.init(),progress:progress)
        if !good.passed {throw LabError.measurement("组合细节独立验证失败："+good.rows.filter{$0.status != .passed}.map(\.detail).joined(separator:"；"))}
        var relabelled=detail.measurements
        for i in relabelled.frames.indices {relabelled.frames[i].actualConditions.iso=100;relabelled.frames[i].step.expectedISO=100}
        do{_=try CombinedValidation.run(proposal:dp,baseline:.standard,measurements:relabelled,resources:.init());failures+=1}catch is CancellationError{throw CancellationError()}catch{}
        var noisy=dp;noisy.profile.parameters.noise.enabled=true;noisy.profile.parameters.noise.curve = .init(function:.init(family:.constant,start:0.05,end:0.05))
        if (try CombinedValidation.run(proposal:noisy,baseline:.standard,measurements:detail.measurements,resources:.init(),progress:progress)).passed {failures+=1}
        let glow=try GlowDeveloperCheck.fixture();defer{glow.cleanup()}
        let gp=try GlowSolver.solve(measurements:glow.bundle,baseline:glow.baseline,options:.init(model:.film,modules:[.glow],baseline:glow.baseline),resources:.init(),progress:progress)
        if !(try CombinedValidation.run(proposal:gp,baseline:glow.baseline,measurements:glow.bundle,resources:.init(),progress:progress)).passed {failures+=1}
        var exposed=gp;exposed.profile.parameters.color.exposureEV=0.5
        if (try CombinedValidation.run(proposal:exposed,baseline:glow.baseline,measurements:glow.bundle,resources:.init(),progress:progress)).passed {failures+=1}
        let condition=try ConditionDeveloperCheck.run(progress:progress)
        if condition["rejectUnsupportedAxis"] != 0 || (condition["heldOutCondition"] ?? .infinity)>0.10 {failures+=1}
        return ["perModuleRegression":failures]
    }
}
