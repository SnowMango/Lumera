import ImageRendering
import Foundation
import Metal
import ImagingCore

/// Isolated developer experiment. This API is deliberately not used by CalibrationService.
/// Its input is an already-rendered frame; upload is included in experiment wall time,
/// so these checks are accuracy evidence, not a production GPU fitting speed benchmark.
public final class ExperimentalGPUFeatureMeasurement {
    private let device:MTLDevice
    private var noise:GPUNoiseMeasurement?,edge:GPUEdgeMeasurement?,glow:GPUGlowMeasurement?
    private var texture:MTLTexture?
    public var deviceName:String {device.name}
    public init() throws {
        guard let d=MTLCreateSystemDefaultDevice() else{throw LabError.noMetal};device=d
    }
    public func measure(_ image:ImageFrame,region:Region=Region(),kind:MeasurementKind,scale:Double=1) throws -> GPUFeatureStatistics {
        try Task.checkCancellation();try image.validateStorage()
        guard image.pixels.allSatisfy({(0...1).contains($0)}) else{throw LabError.measurement("GPU 特征实验仅支持已归一化的 SDR 图像")}
        if texture?.width != image.width || texture?.height != image.height {
            let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba32Float,width:image.width,height:image.height,mipmapped:false)
            d.storageMode = .shared;d.usage = .shaderRead
            guard let t=device.makeTexture(descriptor:d) else{throw LabError.io("GPU 特征实验纹理分配失败")};texture=t
        }
        let t=texture!
        image.pixels.withUnsafeBytes{t.replace(region:MTLRegionMake2D(0,0,image.width,image.height),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:image.width*16)}
        switch kind {
        case .noise,.texture:
            if noise == nil {noise=try GPUNoiseMeasurement(device:device)}
            return try noise!.measure(t,region:region,kind:kind,scale:scale)
        case .edge:
            if edge == nil {edge=try GPUEdgeMeasurement(device:device)}
            return try edge!.measure(t,region:region,scale:scale)
        case .glow:
            if glow == nil {glow=try GPUGlowMeasurement(device:device)}
            return try glow!.measure(t,region:region,scale:scale)
        case .vignette:throw LabError.measurement("暗角使用单独的 GPU 解析实验")
        }
    }
}
