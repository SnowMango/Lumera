import ImageRendering
import Foundation
import Metal
import ImagingCore

/// 共享效果渲染链路的像素、预览和 GPU 测量适配器。
public final class MetalRenderer: @unchecked Sendable {
    let device:MTLDevice, queue:MTLCommandQueue
    let session:ReferenceRenderSession
    let lock=NSLock()
    var pipelines:[String:MTLComputePipelineState]=[:]
    var patchMeasurement:GPUPatchMeasurement?
    var radialReducer:GPURadialReducer?
    var noiseMeasurement:GPUNoiseMeasurement?,edgeMeasurement:GPUEdgeMeasurement?,glowMeasurement:GPUGlowMeasurement?
    var lastWork:ReferenceRenderWork { get {session.lastWork} set {session.lastWork=newValue} }
    var cachedBytes:Int {session.cachedBytes}
    public var deviceName:String {device.name}
    public var memoryStatistics:[String:String] {
        lock.lock();defer{lock.unlock()}
        return ["cachedTextureBytes":String(session.cachedBytes),"pooledTextureBytes":String(session.pooledBytes),"metalAllocatedBytes":String(device.currentAllocatedSize),"cachedInputs":String(session.cachedInputCount),"cachedMeasurementBufferBytes":String((radialReducer?.cachedBufferBytes ?? 0)+(glowMeasurement?.cachedBufferBytes ?? 0))]
    }
    public convenience init(cacheLimitBytes:Int?=nil)throws {
        guard let device=MTLCreateSystemDefaultDevice()else{throw LabError.noMetal}
        try self.init(device:device,cacheLimitBytes:cacheLimitBytes)
    }
    public init(device:MTLDevice,cacheLimitBytes:Int?=nil)throws {
        guard let queue=device.makeCommandQueue()else{throw LabError.noMetal}
        self.device=device;self.queue=queue
        session=try ReferenceRenderSession(device:device,cacheLimitBytes:cacheLimitBytes)
        let library=try RenderingResources.makeLibrary(device:device)
        guard let function=library.makeFunction(name:"previewDisplay")else{throw LabError.noMetal}
        pipelines["previewDisplay"]=try device.makeComputePipelineState(function:function)
    }
    public func releaseCaches(){
        lock.lock();defer{lock.unlock()}
        session.releaseCaches();radialReducer?.releaseCaches();glowMeasurement?.releaseCaches()
    }
    /// 准备可直接用于测量的规范参考图像，并保留来源信息。
    public func prepareReferenceImage(_ image:ImageFrame)throws->ImageFrame {
        try autoreleasepool {
            lock.lock();defer{lock.unlock()}
            try image.validateStorage(allowAlphaNormalization:true)
            guard let pixels=try session.prepareReferencePixels(image.pixels,descriptor:image.descriptor) else {return try ImageCodec.normalizedMaterial(image)}
            var result=try ImageFrame(width:image.width,height:image.height,pixels:pixels)
            result.provenance=image.provenance
            return result
        }
    }
    func download(_ texture:MTLTexture)throws->ImageFrame {
        lastWork.readbackBytes += texture.width*texture.height*16
        var floats=[Float](repeating:0,count:texture.width*texture.height*4)
        floats.withUnsafeMutableBytes{texture.getBytes($0.baseAddress!,bytesPerRow:texture.width*16,from:MTLRegionMake2D(0,0,texture.width,texture.height),mipmapLevel:0)}
        return try ImageFrame(width:texture.width,height:texture.height,pixels:floats)
    }
    func complete(_ command:MTLCommandBuffer)throws {try session.complete(command)}
    /// 在共享会话的纹理租约内完成读取或测量，回调结束后渲染目标可回收。
    func renderReadback<T>(_ image:ImageFrame,style:ResolvedStyle,correction:DeviceCorrection?=nil,resources:RenderResources = .init(),request:RenderRequest,consume:(MTLTexture,MTLTexture?,MTLCommandBuffer)throws->T)throws->T {
        try autoreleasepool {
            lock.lock();defer{lock.unlock()}
            try image.descriptor.validate()
            guard image.descriptor==request.input,image.width==request.input.width,image.height==request.input.height,
                  image.pixels.count==image.width*image.height*4 else{throw LabError.invalid("图像与输入声明不一致")}
            return try session.withRenderedTexture(pixels:image.pixels,style:style,correction:correction,resources:resources,request:request) {texture,command in
                try consume(texture,nil,command)
            }
        }
    }
    /// 执行共享效果链路并读回图像，返回包含处理身份和耗时的结果。
    public func render(_ image:ImageFrame,style:ResolvedStyle,correction:DeviceCorrection? = nil,resources:RenderResources = .init(),request:RenderRequest) throws -> RenderResult {
        let started=ProcessInfo.processInfo.systemUptime
        return try renderReadback(image,style:style,correction:correction,resources:resources,request:request) {current,layer,command in
            try complete(command)
            let renderedAt=ProcessInfo.processInfo.systemUptime
            let output=try download(current),glowImage=try layer.map{try download($0)}
            let downloadedAt=ProcessInfo.processInfo.systemUptime
            let profileDigest=style.profileDigest,inputDigest=image.provenance["fileSHA256"] ?? image.digest
            let finished=ProcessInfo.processInfo.systemUptime
            let timing=RenderTiming(waitAndValidationSeconds:lastWork.preparationStarted-started,
                inputPreparationSeconds:lastWork.inputPrepared-lastWork.preparationStarted,
                correctionSeconds:lastWork.correctionSeconds,effectsSeconds:renderedAt-lastWork.inputPrepared,readbackSeconds:downloadedAt-renderedAt,
                metadataSeconds:finished-downloadedAt,gpuSeconds:lastWork.gpuSeconds,
                reusedInput:lastWork.uploads==0,reusedEffects:lastWork.prefixHits>0)
            let identity = try RenderIdentity.fromValidated(style:style,resources:resources,correction:correction,request:request,precision:.float32)
            let manifest=RenderManifest(renderIdentity:identity,profileDigest:profileDigest,effectiveDigest:style.effectiveDigest,inputDigest:inputDigest,lutDigest:resources.lut?.sha256 ?? "identity",device:device.name,quality:request.maximumLongEdge == nil ? "final":"preview",correctionDigest:lastWork.correctionDigest,width:output.width,height:output.height,timing:timing,seconds:timing.totalSeconds,seed:request.seed,frameIndex:request.frameIndex,input:request.input,previewGlow:request.previewGlow,assumptions:image.provenance.merging(["opticalProcessingScales":"glow=1/\(request.glowScale.rawValue); halation=1/\(request.halationScale.rawValue); softening=1/\(request.softeningScale.rawValue)","sourceNoise":"not estimated","domain":"linear exposure/WB/matrix; encoded LUT/tone/detail; linear softening/vignette/bloom/halation/resize; encoded sensor-noise/film-grain","clipping":"intentional at bounded LUT/non-neutral tone and final output; no intermediate color clamp"]){_,v in v},peakWorkingSetEstimateBytes:max(image.width*image.height,output.width*output.height)*16*8)
            return RenderResult(image:output,glowLayer:glowImage,manifest:manifest)
        }
    }
    /// 返回显示用 GPU 纹理与渲染清单，预览路径无需读回像素。
    public func renderPreview(_ image:ImageFrame,style:ResolvedStyle,correction:DeviceCorrection? = nil,resources:RenderResources = .init(),request:RenderRequest) throws -> MetalPreviewFrame {
        let started=ProcessInfo.processInfo.systemUptime
        return try renderReadback(image,style:style,correction:correction,resources:resources,request:request) {current,_,command in
            let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:current.width,height:current.height,mipmapped:false)
            descriptor.storageMode = .shared;descriptor.usage=[.shaderRead,.shaderWrite]
            guard let output=device.makeTexture(descriptor:descriptor),let pipeline=pipelines["previewDisplay"],
                  let encoder=command.makeComputeCommandEncoder() else {throw LabError.io("无法创建预览纹理")}
            encoder.label="Pack photo preview on GPU"
            encoder.setComputePipelineState(pipeline);encoder.setTexture(current,index:0);encoder.setTexture(output,index:1)
            encoder.dispatchThreads(MTLSize(width:output.width,height:output.height,depth:1),threadsPerThreadgroup:MTLSize(width:16,height:16,depth:1))
            encoder.endEncoding();lastWork.dispatches += 1
            try complete(command)
            let renderedAt=ProcessInfo.processInfo.systemUptime
            let profileDigest=style.profileDigest,inputDigest=image.provenance["fileSHA256"] ?? image.digest
            let finished=ProcessInfo.processInfo.systemUptime
            let timing=RenderTiming(waitAndValidationSeconds:lastWork.preparationStarted-started,
                inputPreparationSeconds:lastWork.inputPrepared-lastWork.preparationStarted,
                correctionSeconds:lastWork.correctionSeconds,effectsSeconds:renderedAt-lastWork.inputPrepared,readbackSeconds:0,
                metadataSeconds:finished-renderedAt,gpuSeconds:lastWork.gpuSeconds,
                reusedInput:lastWork.uploads==0,reusedEffects:lastWork.prefixHits>0)
            let identity = try RenderIdentity.fromValidated(style:style,resources:resources,correction:correction,request:request,precision:.float32)
            let manifest=RenderManifest(renderIdentity:identity,profileDigest:profileDigest,effectiveDigest:style.effectiveDigest,inputDigest:inputDigest,lutDigest:resources.lut?.sha256 ?? "identity",device:device.name,quality:request.maximumLongEdge == nil ? "final":"preview",correctionDigest:lastWork.correctionDigest,width:output.width,height:output.height,timing:timing,seconds:timing.totalSeconds,seed:request.seed,frameIndex:request.frameIndex,input:request.input,previewGlow:request.previewGlow,
                assumptions:image.provenance.merging(["opticalProcessingScales":"glow=1/\(request.glowScale.rawValue); halation=1/\(request.halationScale.rawValue); softening=1/\(request.softeningScale.rawValue)","displayPath":"MTKView; GPU texture; no pixel readback","displayEncoding":"sRGB encoded; BGRA8 opaque; no additional transfer","domain":"linear exposure/WB/matrix; encoded LUT/tone/detail; linear softening/vignette/bloom/halation/resize; encoded sensor-noise/film-grain","clipping":"intentional at bounded LUT/non-neutral tone and final output; no intermediate color clamp"]){_,v in v},peakWorkingSetEstimateBytes:max(image.width*image.height,output.width*output.height)*16*8)
            return MetalPreviewFrame(texture:output,manifest:manifest)
        }
    }
}

/// 已完成的显示纹理及渲染清单。持有此值可跨后续渲染保留预览像素。
public final class MetalPreviewFrame: @unchecked Sendable {
    public let texture:MTLTexture
    public let manifest:RenderManifest
    fileprivate init(texture:MTLTexture,manifest:RenderManifest) {self.texture=texture;self.manifest=manifest}
}
