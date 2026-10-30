import Foundation
import ImagingCore

struct ColorPatchPair:Sendable {
    var group:String,id:String,kind:TargetRegionKind,input:[Double],target:[Double],training:Bool
}
enum ToneColorMeasurement {
    static func pairs(_ bundle:MeasurementBundle) throws -> [ColorPatchPair] {
        let frames=bundle.frames.filter{$0.step.target == .composite}
        guard !frames.isEmpty,frames.count<=200,Set(frames.map(\.fileDigest)).count==frames.count,
              Set(frames.map{$0.step.id}).count==frames.count else {throw LabError.measurement("综合板照片缺失、重复或过多")}
        guard frames.count==54 else {throw LabError.measurement("颜色测量需要完整的 54 张综合板照片，不能省略高档或留出组")}
        for frame in frames {
            let s=frame.step
            guard (0...2).contains(s.conditionIndex),[-1.0,0,1].contains(s.exposureEV),(0...2).contains(s.repeatIndex),
                  s.purpose == ((s.conditionIndex==1 || s.repeatIndex==2) ? .validation:.training),
                  s.id == "\(s.role.rawValue)-composite-\(s.conditionIndex)-\(Int(s.exposureEV))-\(s.repeatIndex)" else {throw LabError.measurement("拍摄步骤或固定留出划分已变更，不能用于求解")}
            if s.role == .input,frame.sourceURL==nil,frame.patches.contains(where:{$0.variance.contains(where:{$0>1e-12})}) {
                throw LabError.measurement("色块有像素起伏，必须保留原始照片用于 GPU 区域验证，不能仅验证平均颜色")
            }
        }
        var result=[ColorPatchPair]()
        let grouped=Dictionary(grouping:frames,by:{$0.step.pairKey})
        for key in grouped.keys.sorted() {
            let group=grouped[key]!
            guard group.count==2,let a=group.first(where:{$0.step.role == .input}),let b=group.first(where:{$0.step.role == .target}),
                  a.step.purpose==b.step.purpose else {throw LabError.measurement("\(key)：缺少唯一的原图/参考对应，或训练验证划分冲突")}
            for frame in group {
                guard frame.width>=1200,frame.height>=1200 else {throw LabError.measurement("综合板尺寸不足")}
                let issues=CaptureQuality.evaluate(patches:frame.patches,conditions:frame.actualConditions,step:frame.step)
                guard issues.isEmpty else {throw LabError.measurement("\(frame.step.id)："+issues.joined(separator:"；"))}
            }
            let target=Dictionary(uniqueKeysWithValues:b.patches.map{($0.id,$0)})
            for patch in a.patches where patch.kind == .gray || patch.kind == .color {
                let index=Int(patch.id.split(separator:"-").last!)!
                // Fixed, declared color hold-out. Never chosen after inspecting residuals.
                let heldOutColor=patch.kind == .color && index%3==2
                result.append(.init(group:key,id:patch.id,kind:patch.kind,input:patch.mean,target:target[patch.id]!.mean,training:a.step.purpose == .training && !heldOutColor))
            }
        }
        let train=frames.filter{$0.step.role == .input && $0.step.purpose == .training}
        guard Set(train.map{$0.step.exposureEV})==Set([-1.0,0,1]),
              frames.contains(where:{$0.step.conditionIndex==1 && $0.step.purpose == .validation}),
              frames.filter({$0.step.conditionIndex==1}).allSatisfy({$0.step.purpose == .validation}),
              result.filter({$0.training && $0.kind == .color}).count>=24 else {throw LabError.measurement("颜色需要低/高条件的三档曝光与独立中档验证；不能只用一档曝光或重复帧替代")}
        return result
    }
}
