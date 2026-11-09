import Foundation
import Metal
import ImagingCore
import ImageRendering

extension MetalRenderer {
    /// 渲染候选并返回紧凑色块统计。区域保留原始色板坐标，通过提供的投影变换定位。
    public func renderPatchStatistics(_ image:ImageFrame,style:ResolvedStyle,correction:DeviceCorrection?=nil,resources:RenderResources = .init(),transform:ProjectiveTransform,regions:[TargetRegion]) throws -> [PatchMeasurement] {
        try renderReadback(image,style:style,correction:correction,resources:resources,request:RenderRequest(input:image.descriptor)) {texture,_,command in
            try complete(command)
            if patchMeasurement == nil {patchMeasurement=try GPUPatchMeasurement(device:device)}
            return try patchMeasurement!.measure(texture,transform:transform,regions:regions)
        }
    }
    func renderLightSignature(_ image:ImageFrame,style:ResolvedStyle,resources:RenderResources,measurement:GPULightMeasurement)throws->LightSignature {
        try renderReadback(image,style:style,resources:resources,request:RenderRequest(input:image.descriptor)) {texture,_,command in
            try complete(command);return try measurement.measure(texture)
        }
    }
    /// 在池化目标回收前复制中央方形区域，边长为 256 至 512 个原生像素。
    func renderGenerationCrop(_ image:ImageFrame,style:ResolvedStyle,resources:RenderResources,seed:UInt32) throws ->MTLTexture {
        var request=RenderRequest(input:image.descriptor);request.seed=seed
        return try renderReadback(image,style:style,resources:resources,request:request) {texture,_,command in
            let side=min(512,min(texture.width,texture.height))
            guard side>=256 else {throw LabError.measurement("平场图片像素不足")}
            let desc=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba32Float,width:side,height:side,mipmapped:false)
            desc.storageMode = .private;desc.usage=[.shaderRead,.shaderWrite]
            guard let copy=device.makeTexture(descriptor:desc),let blit=command.makeBlitCommandEncoder() else {throw LabError.noMetal}
            blit.copy(from:texture,sourceSlice:0,sourceLevel:0,sourceOrigin:.init(x:(texture.width-side)/2,y:(texture.height-side)/2,z:0),sourceSize:.init(width:side,height:side,depth:1),to:copy,destinationSlice:0,destinationLevel:0,destinationOrigin:.init(x:0,y:0,z:0))
            blit.endEncoding();try complete(command);return copy
        }
    }
    /// 渲染候选并读取指定区域及类别的紧凑 GPU 诊断统计。
    public func renderFeatureStatistics(_ image:ImageFrame,style:ResolvedStyle,resources:RenderResources = .init(),request:RenderRequest,region:Region=Region(),kind:MeasurementKind) throws -> GPUFeatureStatistics {
        try renderReadback(image,style:style,resources:resources,request:request) {texture,_,command in
            try featureStatistics(texture,region:region,kind:kind,scale:1,renderCommand:command)
        }
    }
    /// 直接测量规范参考像素。scale 为参考图像素换算比例，允许范围为 0.05 至 20。
    public func measureFeatureStatistics(_ image:ImageFrame,region:Region=Region(),kind:MeasurementKind,scale:Double=1) throws -> GPUFeatureStatistics {
        try autoreleasepool {try measureFeatureStatisticsLocked(image,region:region,kind:kind,scale:scale)}
    }
    private func measureFeatureStatisticsLocked(_ image:ImageFrame,region:Region,kind:MeasurementKind,scale:Double) throws -> GPUFeatureStatistics {
        try image.validateStorage()
        lock.lock();defer{lock.unlock()};try Task.checkCancellation()
        return try session.withInputTexture(pixels:image.pixels,descriptor:image.descriptor) {texture in
            try featureStatistics(texture,region:region,kind:kind,scale:scale,renderCommand:nil)
        }
    }
    /// 从候选渲染中提取全图径向亮度曲线及均值。
    public func renderRadialStatistics(_ image:ImageFrame,style:ResolvedStyle,request:RenderRequest) throws -> RadialStatistics {
        let stats=try renderFeatureStatistics(image,style:style,request:request,kind:.vignette)
        return RadialStatistics(radial:stats.curves["radial"]!,mean:stats.metrics["mean"]!)
    }
    private func featureStatistics(_ texture:MTLTexture,region:Region,kind:MeasurementKind,scale:Double,renderCommand:MTLCommandBuffer?) throws -> GPUFeatureStatistics {
        try Task.checkCancellation();try region.validate()
        guard scale.isFinite,(0.05...20).contains(scale) else {throw LabError.measurement("参考图像素换算比例应在 0.05–20 之间")}
        var stats:GPUFeatureStatistics
        if kind == .vignette {
            if radialReducer == nil {radialReducer=try GPURadialReducer(device:device)}
            guard let cmd=renderCommand ?? queue.makeCommandBuffer() else {throw LabError.noMetal}
            cmd.label="CCDLab render + GPU vignette measurement"
            try radialReducer!.encode(texture,command:cmd,region:region)
            lastWork.dispatches+=2;try complete(cmd)
            let radial=try radialReducer!.read()
            let x=Int(region.x*Double(texture.width)),y=Int(region.y*Double(texture.height))
            let w=min(texture.width-x,Int(region.width*Double(texture.width))),h=min(texture.height-y,Int(region.height*Double(texture.height)))
            stats=GPUFeatureStatistics(metrics:["mean":radial.mean,"edgeEV":-log2(max(1e-8,radial.radial.last!))],curves:["radial":radial.radial],warnings:["暗角测量须使用均匀照明的全幅平面；此方法无法区分照明不均与镜头暗角。"],width:w,height:h,readbackBytes:512,submissions:1,gpuSeconds:lastWork.gpuSeconds ?? 0)
        } else {
            // 跨队列测量前等候效果写入完成。纹理租约持续到测量返回。
            if let cmd=renderCommand {try complete(cmd)}
            switch kind {
            case .noise,.texture:
                if noiseMeasurement == nil {noiseMeasurement=try GPUNoiseMeasurement(device:device)}
                stats=try noiseMeasurement!.measure(texture,region:region,kind:kind,scale:scale)
            case .edge:
                if edgeMeasurement == nil {edgeMeasurement=try GPUEdgeMeasurement(device:device)}
                stats=try edgeMeasurement!.measure(texture,region:region,scale:scale)
            case .glow:
                if glowMeasurement == nil {glowMeasurement=try GPUGlowMeasurement(device:device)}
                stats=try glowMeasurement!.measure(texture,region:region,scale:scale)
            case .vignette:preconditionFailure("handled above")
            }
            lastWork.submissions+=stats.submissions
            lastWork.gpuSeconds=(lastWork.gpuSeconds ?? 0)+stats.gpuSeconds
        }
        lastWork.readbackBytes+=stats.readbackBytes
        return stats
    }
}
