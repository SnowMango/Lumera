import Foundation
import ImagingCore

/// One decoded source at a time. Compact measurements may be cached; full photos are not accumulated.
final class GenerationImages {
    private var cached:(URL,Date?,ImageFrame)?
    func load(_ frame:FrameMeasurements) throws ->ImageFrame {
        try Task.checkCancellation()
        guard let url=frame.sourceURL else {throw LabError.measurement("需要原始照片文件，不能仅凭汇总指标生成空间效果")}
        let date=(try FileManager.default.attributesOfItem(atPath:url.path)[.modificationDate]) as? Date
        let image:ImageFrame
        if let c=cached,c.0==url,c.1==date {image=c.2}
        else {cached=nil;image=try ImageCodec.load(url);cached=(url,date,image)}
        guard image.width==frame.width,image.height==frame.height,image.provenance["fileSHA256"]==frame.fileDigest else {throw LabError.measurement("照片内容或尺寸已变化，请重新导入测量")}
        return image
    }
    static func region(_ id:String,frame:FrameMeasurements)throws->Region {
        guard let pose=frame.pose,let area=TargetLayout.composite.regions.first(where:{$0.id==id}) else {throw LabError.measurement("缺少目标板定位")}
        // Keep the printed block's outer white/background boundary out of the
        // edge-position estimator and pattern spectrum. Measure only its interior.
        let r=area.rect
        let interior=TargetRect(x:r.x+r.width*0.1,y:r.y+r.height*0.1,width:r.width*0.8,height:r.height*0.8)
        let corners=interior.corners.map{pose.project($0)}
        guard corners.allSatisfy({$0.x.isFinite && $0.y.isFinite}) else {throw LabError.measurement("定位变换无效")}
        let xs=corners.map(\.x),ys=corners.map(\.y)
        let roi=Region(x:xs.min()!/Double(frame.width),y:ys.min()!/Double(frame.height),width:(xs.max()!-xs.min()!)/Double(frame.width),height:(ys.max()!-ys.min()!)/Double(frame.height))
        try roi.validate();return roi
    }
    static func relativeScale(input:FrameMeasurements,target:FrameMeasurements)throws->Double {
        guard let a=input.pose,let b=target.pose else {throw LabError.measurement("缺少原始像素尺度")}
        let p=TargetPoint(x:0.33,y:0.7),px=TargetPoint(x:0.34,y:0.7),py=TargetPoint(x:0.33,y:0.71)
        let rx=a.project(p).distance(to:a.project(px))/b.project(p).distance(to:b.project(px))
        let ry=a.project(p).distance(to:a.project(py))/b.project(p).distance(to:b.project(py))
        guard rx.isFinite,ry.isFinite,(0.5...2).contains(rx),(0.5...2).contains(ry),abs(log2(rx/ry))<0.03 else {throw LabError.measurement("两图成像尺度/透视差异超出空间测量范围，请正对目标板重拍")}
        return sqrt(rx*ry)
    }
}
struct ModuleCapturePair {
    var input:FrameMeasurements,target:FrameMeasurements,training:Bool
    static func composite(_ bundle:MeasurementBundle,condition:Int)throws->[Self] {
        guard [0,2].contains(condition) else {throw LabError.measurement("中间条件固定用于验证，不能直接参与参数选择")}
        let frames=bundle.frames.filter{$0.step.target == .composite && $0.step.conditionIndex==condition}
        guard frames.count==18,Set(frames.map{$0.step.id}).count==18,Set(frames.map(\.fileDigest)).count==18 else {throw LabError.measurement("当前条件需要两设备各三档曝光、每档三张综合板")}
        for f in frames {
            let s=f.step
            guard CaptureQuality.evaluate(patches:f.patches,conditions:f.actualConditions,step:s).isEmpty else {throw LabError.measurement("综合板质量未通过，不能绕过裁切/反光/完整区域检查")}
            guard [-1.0,0,1].contains(s.exposureEV),(0...2).contains(s.repeatIndex),s.purpose == (s.repeatIndex==2 ? .validation:.training),
                  s.id=="\(s.role.rawValue)-composite-\(condition)-\(Int(s.exposureEV))-\(s.repeatIndex)",
                  let iso=f.actualConditions.iso,let time=f.actualConditions.exposureDurationSeconds,
                  iso.isFinite,time.isFinite,iso>0,time>0,s.expectedISO.isFinite,s.expectedISO>0,s.expectedExposureSeconds.isFinite,s.expectedExposureSeconds>0,
                  abs(log2(iso/s.expectedISO))<=0.08,abs(log2(time/s.expectedExposureSeconds))<=0.15 else {throw LabError.measurement("空间测量的步骤/元数据/固定划分不符")}
        }
        for role in CaptureRole.allCases {
            let set=frames.filter{$0.step.role==role},isos=set.compactMap{$0.actualConditions.iso}
            guard let first=isos.first,isos.allSatisfy({abs(log2($0/first))<0.08}),Set(set.map{"\($0.width)x\($0.height)"}).count==1 else {throw LabError.measurement("同一条件的 ISO 或像素尺寸不一致")}
        }
        let groups=Dictionary(grouping:frames,by:{$0.step.pairKey})
        return try groups.keys.sorted().map {key in
            let pair=groups[key]!
            guard pair.count==2,let input=pair.first(where:{$0.step.role == .input}),let target=pair.first(where:{$0.step.role == .target}) else {throw LabError.measurement("缺少唯一原图与参考图对应")}
            // +1 EV is an entire unseen condition within this ISO, beyond repeat holdout.
            return .init(input:input,target:target,training:input.step.repeatIndex<2 && input.step.exposureEV != 1)
        }
    }
}
