import Foundation
import ImagingCore
import ImageRendering

/// 从测量记录指向的已核验原图提供像素。
protocol GenerationImageLoading: AnyObject {
    func load(_ frame:FrameMeasurements)throws->ImageFrame
}
struct DetailObservation {
    let edge:[Double]
    let detailRMS:Double
    let psd:[Double]
}
/// 测量渲染后的色块，或对纯 RGB 样本执行前向颜色预测。
protocol PatchMeasuring {
    func patches(frame:FrameMeasurements,style:ResolvedStyle,resources:RenderResources,regions:[TargetRegion])throws->[PatchMeasurement]
    func predictColors(_ inputs:[[Double]],style:ResolvedStyle)throws->[[Double]]
}
/// 按已标定区域测量边缘曲线、细节 RMS 与功率谱。
protocol DetailMeasuring {
    func detail(frame:FrameMeasurements,style:ResolvedStyle,resources:RenderResources)throws->DetailObservation
}
/// 按候选外观渲染并提取亮源特征。
protocol LightMeasuring {
    func light(frame:FrameMeasurements,style:ResolvedStyle,resources:RenderResources)throws->LightSignature
}
/// 对匹配的帧、候选外观和随机种子测量时序纹理。
protocol TextureMeasuring {
    func texture(frames:[FrameMeasurements],styles:[ResolvedStyle],resources:RenderResources,seeds:[UInt32])throws->TemporalTexture
}
