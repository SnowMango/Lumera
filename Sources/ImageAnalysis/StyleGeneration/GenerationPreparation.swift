import Foundation
import ImagingCore

public enum GenerationPreparation {
    public static func prepare(captures:CaptureSet,resources:GenerationResources,modules:Set<AlgorithmID> = [.toneColor,.detail,.texture,.glow],progress:@Sendable(GenerationProgress)->Void = {_ in})throws->MeasurementBundle {
        try Task.checkCancellation()
        guard captures.protocolVersion=="capture-draft-1",captures.canMeasure,(1...200).contains(captures.records.count),Set(captures.records.map(\.fileDigest)).count==captures.records.count,Set(captures.records.map(\.step.id)).count==captures.records.count else{throw LabError.measurement("采集清单未完成、重复或版本已失效，请先处理导入列表中的问题")}
        let renderer=try MetalRenderer(cacheLimitBytes:128*1024*1024);defer{renderer.releaseCaches()}
        let neutral=try ResolvedStyle(profile:.standard),start=ProcessInfo.processInfo.systemUptime
        let selected=captures.records.filter{GenerationCoordinator.requiredTargets(for:modules).contains($0.step.target)}
        var frames=[FrameMeasurements]()
        for (index,record) in selected.enumerated() {try autoreleasepool {
            try Task.checkCancellation()
            progress(.init(stage:"准备照片 \(record.step.id)",completed:index,total:selected.count,elapsedSeconds:ProcessInfo.processInfo.systemUptime-start))
            let image=try ImageCodec.load(record.url)
            guard image.provenance["fileSHA256"]==record.fileDigest else{throw LabError.measurement("照片内容已变更，请重新导入："+record.url.lastPathComponent)}
            let pose:ProjectiveTransform,regions:[TargetRegion]
            if record.step.target == .composite {
                pose=try TargetDetection.detect(image:image).transform;regions=TargetLayout.composite.regions
            }else {
                pose = .init(coefficients:[Double(image.width),0,0,0,Double(image.height),0,0,0,1])
                let w=min(512.0,Double(image.width))/Double(image.width),h=min(512.0,Double(image.height))/Double(image.height)
                regions=[.init(id:record.step.target.rawValue,kind:record.step.target == .flat ? .flat:.light,rect:record.step.target == .flat ? .init(x:(1-w)/2,y:(1-h)/2,width:w,height:h):.init(x:0,y:0,width:1,height:1),printedRGB:[])]
            }
            let patches=try renderer.renderPatchStatistics(image,style:neutral,transform:pose,regions:regions)
            let issues=CaptureQuality.evaluate(patches:patches,conditions:image.captureConditions,step:record.step)
            guard issues.isEmpty else{throw LabError.measurement(record.step.id+"："+issues.joined(separator:"；"))}
            var frame=FrameMeasurements(fileDigest:record.fileDigest,step:record.step,actualConditions:image.captureConditions,width:image.width,height:image.height,patches:patches,sourceURL:record.url,pose:record.step.target == .composite ? pose:nil)
            if record.step.target == .composite && modules.contains(.detail) {
                let edge=try renderer.measureFeatureStatistics(image,region:GenerationImages.region("edge",frame:frame),kind:.edge)
                let detail=try renderer.measureFeatureStatistics(image,region:GenerationImages.region("detail",frame:frame),kind:.texture)
                frame.metrics=edge.metrics;frame.metrics["detailRMS"]=detail.metrics["rms"]
                frame.curves=edge.curves;frame.curves["detailPSD"]=detail.curves["psd"]
            }
            frames.append(frame)
            progress(.init(stage:"已检查 \(record.step.id)",completed:index+1,total:selected.count,elapsedSeconds:ProcessInfo.processInfo.systemUptime-start))
        }}
        return .init(frames:frames,resourceDigests:resources.digests)
    }
}
