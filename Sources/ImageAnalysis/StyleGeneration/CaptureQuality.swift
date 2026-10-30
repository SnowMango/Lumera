import Foundation
import ImagingCore

public struct PatchMeasurement:Codable,Equatable,Sendable {
    public var id:String,kind:TargetRegionKind,mean:[Double],variance:[Double],clippedFraction:Double,pixelCount:Int
}
public struct FrameMeasurements:Codable,Equatable,Sendable {
    public var fileDigest:String,step:CaptureStep,actualConditions:CaptureConditions,width:Int,height:Int,patches:[PatchMeasurement]
    public var sourceURL:URL?=nil
    public var pose:ProjectiveTransform?,metrics:[String:Double]=[:],curves:[String:[Double]]=[:]
}
public struct MeasurementBundle:Codable,Equatable,Sendable {
    public var frames:[FrameMeasurements],resourceDigests:[String:String]
}
public enum CaptureQuality {
    /// Conservative quality checks. A pass does not prove print reflectance, illumination uniformity or identifiability.
    public static func evaluate(patches:[PatchMeasurement],conditions:CaptureConditions,step:CaptureStep)->[String] {
        var issues=[String]()
        guard step.expectedISO.isFinite,step.expectedISO>0,step.expectedExposureSeconds.isFinite,step.expectedExposureSeconds>0 else {return ["拍摄步骤包含无效 ISO 或快门，请重新规划"]}
        if let iso=conditions.iso,iso.isFinite,iso>0 {
            if abs(log2(iso/step.expectedISO))>0.08 {issues.append("ISO 与当前步骤不符，请检查组别")}
        } else {issues.append("缺少有效 ISO 元数据，不能生成条件响应")}
        if let duration=conditions.exposureDurationSeconds,duration.isFinite,duration>0 {
            if abs(log2(duration/step.expectedExposureSeconds))>0.15 {issues.append("实际快门偏离试拍计划，请按实际设备能力重新规划")}
        } else {issues.append("缺少有效快门元数据，无法排除曝光混配")}
        let required:[String:TargetRegionKind]
        switch step.target {
        case .composite:required=Dictionary(uniqueKeysWithValues:TargetLayout.composite.regions.map{($0.id,$0.kind)})
        case .flat:required=["flat":.flat]
        case .light:required=["light":.light]
        }
        if patches.count != required.count || Set(patches.map(\.id)).count != patches.count || patches.contains(where:{required[$0.id] != $0.kind}) {
            issues.append("测量区域缺失、重复或类型不符；需要完整目标的唯一对应区域")
        }
        for patch in patches {
            guard patch.pixelCount>=256,patch.mean.count==3,patch.variance.count==3,
                  patch.mean.allSatisfy({$0.isFinite && (0...1).contains($0)}),patch.variance.allSatisfy({$0.isFinite && $0>=0}),patch.clippedFraction.isFinite,(0...1).contains(patch.clippedFraction) else {
                issues.append("\(patch.id)：采样不足或测量无效");continue
            }
            if patch.clippedFraction>0.01 {issues.append("\(patch.id)：超过 1% 像素已到黑白裁切端，请调整基准曝光重拍")}
            if [.gray,.color,.flat].contains(patch.kind),patch.variance.max()!>0.0016 {
                issues.append("\(patch.id)：区域内亮度起伏过大，检查反光、纸张不平、照明或已有噪点")
            }
        }
        return issues
    }
}
