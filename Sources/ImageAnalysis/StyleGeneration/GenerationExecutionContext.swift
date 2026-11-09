import Foundation
import Metal
import ImagingCore

/// 一次串行制作操作共用的设备、渲染器、原图缓存与测量服务。
/// 调用方提供的上下文仍由调用方持有。独立入口负责清理自己创建的上下文。
public final class GenerationExecutionContext {
    let device:MTLDevice
    let renderer:MetalRenderer
    let images:GenerationImages
    private var lightMeasurement:GPULightMeasurement?
    private var temporalMeasurement:GPUTemporalTexture?
    var measurements:MetalGenerationMeasurements { MetalGenerationMeasurements(context:self) }
    /// 在指定 Metal 设备上建立制作上下文。cacheLimitBytes 为渲染器纹理缓存的字节预算。
    public init(device:MTLDevice?=MTLCreateSystemDefaultDevice(),cacheLimitBytes:Int=128*1024*1024)throws {
        guard cacheLimitBytes>=0 else{throw LabError.invalid("纹理缓存预算不能为负数")}
        guard let device else{throw LabError.noMetal}
        self.device=device
        renderer=try MetalRenderer(device:device,cacheLimitBytes:cacheLimitBytes)
        images=GenerationImages()
    }
    func light()throws->GPULightMeasurement {
        if let lightMeasurement{return lightMeasurement}
        let value=try GPULightMeasurement(device:device);lightMeasurement=value;return value
    }
    func temporal()throws->GPUTemporalTexture {
        if let temporalMeasurement{return temporalMeasurement}
        let value=try GPUTemporalTexture(device:device);temporalMeasurement=value;return value
    }
    /// 释放渲染与原图缓存，并丢弃延迟创建的测量服务。
    public func releaseCaches(){renderer.releaseCaches();images.releaseCaches();lightMeasurement=nil;temporalMeasurement=nil}
    /// 阶段切换时清除原图缓存，使下一阶段重新核对文件内容。
    func beginStage(){images.releaseCaches()}
}
