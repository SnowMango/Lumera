import Foundation
import ImagingCore
import ImageRendering

/// 复用制作上下文，把候选效果渲染与相应 GPU 统计接入各求解器。
struct MetalGenerationMeasurements:PatchMeasuring,DetailMeasuring,LightMeasuring,TextureMeasuring {
    let context:GenerationExecutionContext
    func patches(frame:FrameMeasurements,style:ResolvedStyle,resources:RenderResources,regions:[TargetRegion])throws->[PatchMeasurement] {
        guard let pose=frame.pose else{throw LabError.measurement("缺少原始照片定位信息")}
        return try context.renderer.renderPatchStatistics(context.images.load(frame),style:style,resources:resources,transform:pose,regions:regions)
    }
    func predictColors(_ inputs:[[Double]],style:ResolvedStyle)throws->[[Double]] {
        guard !inputs.isEmpty,inputs.allSatisfy({$0.count==3 && $0.allSatisfy(\.isFinite)})else{throw LabError.measurement("缺少有效颜色样本")}
        let image=try ImageFrame(width:inputs.count,height:1,pixels:inputs.flatMap{$0.map(Float.init)+[1]})
        let output=try context.renderer.render(image,style:style,request:.init(input:image.descriptor)).image
        return inputs.indices.map{i in (0..<3).map{Double(output.pixels[i*4+$0])}}
    }
    func detail(frame:FrameMeasurements,style:ResolvedStyle,resources:RenderResources)throws->DetailObservation {
        let image=try context.images.load(frame),request=RenderRequest(input:image.descriptor)
        let edge=try context.renderer.renderFeatureStatistics(image,style:style,resources:resources,request:request,region:GenerationImages.region("edge",frame:frame),kind:.edge)
        let pattern=try context.renderer.renderFeatureStatistics(image,style:style,resources:resources,request:request,region:GenerationImages.region("detail",frame:frame),kind:.texture)
        guard let curve=edge.curves["edge"],let rms=pattern.metrics["rms"],let psd=pattern.curves["psd"] else{throw LabError.measurement("缺少候选细节指标")}
        return DetailObservation(edge:curve,detailRMS:rms,psd:psd)
    }
    func light(frame:FrameMeasurements,style:ResolvedStyle,resources:RenderResources)throws->LightSignature {
        try context.renderer.renderLightSignature(context.images.load(frame),style:style,resources:resources,measurement:context.light())
    }
    /// 在四帧匹配的原生像素裁剪区上测量，种子按帧对应。
    func texture(frames:[FrameMeasurements],styles:[ResolvedStyle],resources:RenderResources,seeds:[UInt32])throws->TemporalTexture {
        guard frames.count==4,styles.count==frames.count,seeds.count==frames.count else{throw LabError.measurement("时序测量需要四组匹配照片、风格与种子")}
        let textures=try frames.indices.map{i in try autoreleasepool {
            try context.renderer.renderGenerationCrop(context.images.load(frames[i]),style:styles[i],resources:resources,seed:seeds[i])
        }}
        return try context.temporal().measure(textures)
    }
}

/// 独立入口仅在求解首次请求测量时创建默认上下文。
final class DefaultGenerationMeasurements:PatchMeasuring,DetailMeasuring,LightMeasuring,TextureMeasuring {
    private let makeContext:()throws->GenerationExecutionContext
    private var context:GenerationExecutionContext?
    init(makeContext:@escaping ()throws->GenerationExecutionContext){self.makeContext=makeContext}
    private func service()throws->MetalGenerationMeasurements {
        if context == nil {context=try makeContext()}
        return context!.measurements
    }
    func releaseCaches(){context?.releaseCaches();context=nil}
    func patches(frame:FrameMeasurements,style:ResolvedStyle,resources:RenderResources,regions:[TargetRegion])throws->[PatchMeasurement]{try service().patches(frame:frame,style:style,resources:resources,regions:regions)}
    func predictColors(_ inputs:[[Double]],style:ResolvedStyle)throws->[[Double]]{try service().predictColors(inputs,style:style)}
    func detail(frame:FrameMeasurements,style:ResolvedStyle,resources:RenderResources)throws->DetailObservation{try service().detail(frame:frame,style:style,resources:resources)}
    func light(frame:FrameMeasurements,style:ResolvedStyle,resources:RenderResources)throws->LightSignature{try service().light(frame:frame,style:style,resources:resources)}
    func texture(frames:[FrameMeasurements],styles:[ResolvedStyle],resources:RenderResources,seeds:[UInt32])throws->TemporalTexture{try service().texture(frames:frames,styles:styles,resources:resources,seeds:seeds)}
}
