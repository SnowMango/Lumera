import ImageRendering
import Foundation
import Metal
import ImagingCore

/// One instance serializes command encoding; GUI/CLI share precisely this pipeline.
public final class MetalRenderer: @unchecked Sendable {
    private let device: MTLDevice, queue: MTLCommandQueue
    private var pipelines: [String:MTLComputePipelineState] = [:]
    private var materialPipeline:MTLComputePipelineState?
    private let lock = NSLock()
    private let pool: TexturePool
    private var patchMeasurement:GPUPatchMeasurement?
    private var radialReducer:GPURadialReducer?
    private var noiseMeasurement:GPUNoiseMeasurement?,edgeMeasurement:GPUEdgeMeasurement?,glowMeasurement:GPUGlowMeasurement?
    private var command: MTLCommandBuffer?
    private var inputs: [InputKey: CachedInput] = [:]
    private var lastUse: UInt64 = 0
    private var gaussianWeights:[UInt64:(PreparedGaussianKernel,MTLBuffer)]=[:]
    private var correctionCache:(String,PreparedDeviceCorrection?)?
    private var correctionLUTCache:PreparedLUT?
    private var lutCache: (String, MTLTexture)?
    // Bounded per renderer; tuning this does not change numerical output.
    var cacheLimitBytes: Int
    private(set) var lastWork = RenderWork()
    var cachedBytes: Int { inputs.values.reduce(0) { $0 + $1.byteCount } }

    /// Tracked texture/buffer caches; process memory also includes CPU pixels and driver allocations.
    public var memoryStatistics:[String:String] {
        lock.lock();defer{lock.unlock()}
        return ["cachedTextureBytes":String(cachedBytes),"pooledTextureBytes":String(pool.bytes),
                "metalAllocatedBytes":String(device.currentAllocatedSize),"cachedInputs":String(inputs.count),
                "cachedMeasurementBufferBytes":String((radialReducer?.cachedBufferBytes ?? 0)+(glowMeasurement?.cachedBufferBytes ?? 0))]
    }
    public func releaseCaches() {
        lock.lock();defer{lock.unlock()}
        inputs.removeAll();lutCache=nil;correctionCache=nil;correctionLUTCache=nil;gaussianWeights.removeAll();pool.removeAll()
        radialReducer?.releaseCaches();glowMeasurement?.releaseCaches()
    }
    public var deviceName: String { device.name }
    public init(cacheLimitBytes requested:Int?=nil) throws {
        guard let device=MTLCreateSystemDefaultDevice(),let queue=device.makeCommandQueue() else {throw LabError.noMetal}
        self.device=device; self.queue=queue
        let recommended=Int(min(UInt64(1_073_741_824),device.recommendedMaxWorkingSetSize/4))
        if let requested,requested<0 {throw LabError.invalid("纹理缓存预算不能为负数")}
        cacheLimitBytes=min(recommended,requested ?? recommended)
        pool=TexturePool(device:device,limit:min(536_870_912,cacheLimitBytes/2))
        let library=try RenderingResources.makeLibrary(device:device)
        for name in ["transfer","lutMap","gaussian","gaussianPrepared","detailCombine","sharpen","vignette","highlights","glowCombine","resizeLinear","randomField","finish","previewDisplay"] + CameraEffectUniforms.kernels {
            guard let f=library.makeFunction(name:name) else {throw LabError.io("缺少图像处理函数： \(name)")}
            pipelines[name]=try device.makeComputePipelineState(function:f)
        }
    }
    /// Canonical 16-bit sRGB material. Opaque pixels match Core Graphics' integer
    /// rounding and Float scale exactly; keep the resulting texture for fitting.
    public func prepareReferenceImage(_ image:ImageFrame) throws -> ImageFrame {
        try autoreleasepool {try prepareReferenceImageLocked(image)}
    }
    private func prepareReferenceImageLocked(_ image:ImageFrame) throws -> ImageFrame {
        lock.lock();defer{lock.unlock()};try Task.checkCancellation()
        let allocations=pool.allocations;lastWork=RenderWork()
        defer{trimCache();lastWork.allocations=pool.allocations-allocations}
        try image.validateStorage(allowAlphaNormalization:true)
        if materialPipeline == nil {
            let options=MTLCompileOptions();options.fastMathEnabled=false
            let library=try device.makeLibrary(source:"""
            #include <metal_stdlib>
            using namespace metal;
            kernel void canonicalMaterial(texture2d<float,access::read> input [[texture(0)]],
                                          texture2d<float,access::write> output [[texture(1)]],
                                          device atomic_uint *flags [[buffer(0)]],uint2 p [[thread_position_in_grid]]) {
                if(p.x>=output.get_width() || p.y>=output.get_height()) return;
                float4 value=input.read(p);
                if(!all(isfinite(value))) atomic_fetch_or_explicit(flags,2u,memory_order_relaxed);
                if(value.a!=1.0f) atomic_fetch_or_explicit(flags,1u,memory_order_relaxed);
                float4 quantized=round(clamp(value,0.0f,1.0f)*65535.0f);
                output.write(quantized*(1.0f/65535.0f),p);
            }
            """,options:options)
            guard let function=library.makeFunction(name:"canonicalMaterial") else{throw LabError.io("缺少标定图像标准化函数")}
            materialPipeline=try device.makeComputePipelineState(function:function)
        }
        let source=try pool.take(image.width,image.height),output=try pool.take(image.width,image.height)
        image.pixels.withUnsafeBytes{source.texture.replace(region:MTLRegionMake2D(0,0,image.width,image.height),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:image.width*16)}
        lastWork.uploads=1
        guard let flags=device.makeBuffer(length:4,options:.storageModeShared),let cmd=queue.makeCommandBuffer(),
              let encoder=cmd.makeComputeCommandEncoder(),let pipeline=materialPipeline else{throw LabError.noMetal}
        flags.contents().storeBytes(of:UInt32(0),as:UInt32.self)
        cmd.label="CCDLab GPU canonical material preparation"
        encoder.setComputePipelineState(pipeline);encoder.setTexture(source.texture,index:0);encoder.setTexture(output.texture,index:1)
        encoder.setBuffer(flags,offset:0,index:0)
        encoder.dispatchThreads(MTLSize(width:image.width,height:image.height,depth:1),threadsPerThreadgroup:MTLSize(width:16,height:16,depth:1))
        encoder.endEncoding();lastWork.dispatches=1;try complete(cmd);lastWork.readbackBytes=4
        let flag=flags.contents().load(as:UInt32.self)
        guard flag&2==0 else{throw LabError.invalid("标定图像包含无效像素")}
        if flag&1 != 0 {
            // Transparent image import has legacy premultiplication quantization.
            // Preserve it instead of silently changing historical calibration evidence.
            return try ImageCodec.normalizedMaterial(image)
        }
        var normalized=try download(output.texture);normalized.provenance=image.provenance
        try Task.checkCancellation()
        let key=normalized.pixels.withUnsafeBufferPointer{InputKey(address:UInt(bitPattern:$0.baseAddress!),width:image.width,height:image.height)}
        lastUse &+= 1
        let entry=CachedInput(pixels:normalized.pixels,texture:output,lastUse:lastUse);entry.checkedSDR=true
        inputs[key]=entry
        return normalized
    }
    private func input(_ image:ImageFrame,key:InputKey,correction:PreparedDeviceCorrection? = nil) throws -> CachedInput {
        lastUse &+= 1
        if let entry=inputs[key] {entry.lastUse=lastUse;return entry}
        var texture=try pool.take(image.width,image.height)
        image.pixels.withUnsafeBytes {texture.texture.replace(region:MTLRegionMake2D(0,0,image.width,image.height),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:image.width*16)}
        lastWork.uploads+=1
        if let correction {
            let started=ProcessInfo.processInfo.systemUptime,before=lastWork.dispatches
            if correction.colorIsActive {texture=try pass("colorResponse",texture,[],correction.color.uniforms)}
            if let lut=correction.lutTexture {texture=try pass("lutMap",texture,lut:lut)}
            lastWork.correctionDispatches=lastWork.dispatches-before
            lastWork.correctionSeconds += ProcessInfo.processInfo.systemUptime-started
        }
        if let limit=key.limit,limit<max(image.width,image.height) {
            // Keep the exact linear-light GPU resampling used by the old preview path.
            // Only its small encoded result survives the command, never the full input.
            let f=Double(limit)/Double(max(image.width,image.height))
            texture=try pass("transfer",texture,[],[-1])
            texture=try pass("resizeLinear",texture,size:(max(1,Int(Double(image.width)*f)),max(1,Int(Double(image.height)*f))))
            texture=try pass("transfer",texture,[],[1])
        }
        // Retaining the array makes its storage identity safe: mutations must copy it.
        let entry=CachedInput(pixels:image.pixels,texture:texture,lastUse:lastUse)
        inputs[key]=entry;return entry
    }
    private func trimCache() {
        while cachedBytes>cacheLimitBytes,let oldest=inputs.min(by:{$0.value.lastUse<$1.value.lastUse})?.key {
            inputs.removeValue(forKey:oldest)
        }
    }
    private func download(_ texture:MTLTexture) throws -> ImageFrame {
        lastWork.readbackBytes += texture.width*texture.height*16
        var floats=[Float](repeating:0,count:texture.width*texture.height*4)
        floats.withUnsafeMutableBytes {texture.getBytes($0.baseAddress!,bytesPerRow:texture.width*16,from:MTLRegionMake2D(0,0,texture.width,texture.height),mipmapLevel:0)}
        return try ImageFrame(width:texture.width,height:texture.height,pixels:floats)
    }
    private func pass(_ name:String,_ input:TextureLease,_ extra:[TextureLease]=[],_ params:[Float]=[0],size:(Int,Int)?=nil,lut:MTLTexture?=nil,weights:MTLBuffer?=nil) throws -> TextureLease {
        try Task.checkCancellation()
        let out=try pool.take(size?.0 ?? input.width,size?.1 ?? input.height)
        guard let pipeline=pipelines[name],let encoder=command?.makeComputeCommandEncoder() else {throw LabError.io("无法创建图像处理任务，请重试")}
        encoder.setComputePipelineState(pipeline);encoder.setTexture(input.texture,index:0);encoder.setTexture(out.texture,index:1)
        for (i,t) in extra.enumerated(){encoder.setTexture(t.texture,index:i+2)}
        if let lut {encoder.setTexture(lut,index:2)}
        if let weights {encoder.setBuffer(weights,offset:0,index:1)}
        params.withUnsafeBytes{encoder.setBytes($0.baseAddress!,length:$0.count,index:0)}
        encoder.dispatchThreads(MTLSize(width:out.width,height:out.height,depth:1),threadsPerThreadgroup:MTLSize(width:16,height:16,depth:1))
        // Tracked textures order dependencies between encoders, including recycled scratch textures.
        encoder.endEncoding();lastWork.dispatches+=1;return out
    }
    private func blur(_ input:TextureLease,sigma:Double,noise:Bool=false,scaleX:Double=1,scaleY:Double=1) throws -> TextureLease {
        func axis(_ source:TextureLease,_ radius:Double,_ direction:Float) throws -> TextureLease {
            if radius<0.08{return source}
            let key=UInt64(Float(radius).bitPattern)*2+(noise ? 1:0)
            let cached:(PreparedGaussianKernel,MTLBuffer)
            if let existing=gaussianWeights[key] {cached=existing}
            else {
                if gaussianWeights.count>=32 {gaussianWeights.removeAll(keepingCapacity:true)}
                let kernel=try PreparedGaussianKernel(sigma:Float(radius),noise:noise)
                guard let buffer=kernel.weights.withUnsafeBytes({device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared)}) else {throw LabError.io("无法分配模糊权重")}
                cached=(kernel,buffer);gaussianWeights[key]=cached
            }
            return try pass("gaussianPrepared",source,[],[Float(cached.0.radius),direction,cached.0.denominator,noise ? 1:0],weights:cached.1)
        }
        return try axis(axis(input,sigma*scaleX,0),sigma*scaleY,1)
    }
    private func detail(_ input:TextureLease,_ p:Detail,_ scale:Double) throws -> TextureLease {
        guard p.isActive else{return input}
        let fine=try blur(input,sigma:p.fineSigma*scale),mid=try blur(input,sigma:p.midSigma*scale)
        let composed=try pass("detailCombine",input,[fine,mid],[Float(p.fineGain),Float(p.midGain)])
        guard p.sharpenAmount>0 else{return composed}
        return try pass("sharpen",composed,[blur(composed,sigma:p.sharpenSigma*scale)],[Float(p.sharpenAmount),Float(p.threshold),Float(p.maxAdjustment)])
    }
    private func glow(_ input:TextureLease,_ p:Glow,_ scale:Double,includeLayer:Bool) throws -> (TextureLease,TextureLease?) {
        guard p.enabled,p.amount>0 else{return(input,nil)}
        let hi=try pass("highlights",input,[],[Float(p.threshold),Float(p.knee)])
        let near=try blur(hi,sigma:p.nearSigma*scale),far=try blur(hi,sigma:p.farSigma*scale)
        let out=try pass("glowCombine",input,[hi,near,far],[Float(p.amount),Float(p.farWeight),0])
        let layer=includeLayer ? try pass("glowCombine",input,[hi,near,far],[Float(p.amount),Float(p.farWeight),1]) : nil
        return(out,layer)
    }
    private func applyLUT(_ input:TextureLease,_ ref:LUTAsset?) throws -> TextureLease {
        guard let ref else{return input}
        if let cached=lutCache,cached.0==ref.sha256 {return try pass("lutMap",input,lut:cached.1)}
        let cube=try ref.decodedCube()
        let d=MTLTextureDescriptor();d.textureType = .type3D;d.pixelFormat = .rgba32Float;d.width=cube.size;d.height=cube.size;d.depth=cube.size;d.storageMode = .shared;d.usage = .shaderRead
        guard let t=device.makeTexture(descriptor:d) else {throw LabError.io("无法为 LUT 分配内存，请重试或使用较小尺寸的 LUT")}
        cube.rgba.withUnsafeBytes{t.replace(region:MTLRegionMake3D(0,0,0,cube.size,cube.size,cube.size),mipmapLevel:0,slice:0,withBytes:$0.baseAddress!,bytesPerRow:cube.size*16,bytesPerImage:cube.size*cube.size*16)}
        lutCache=(ref.sha256,t)
        return try pass("lutMap",input,lut:t)
    }
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
            let manifest=RenderManifest(profileDigest:profileDigest,effectiveDigest:style.effectiveDigest,inputDigest:inputDigest,lutDigest:resources.lut?.sha256 ?? "identity",device:device.name,quality:request.maximumLongEdge == nil ? "final":"preview",correctionDigest:lastWork.correctionDigest,width:output.width,height:output.height,timing:timing,seconds:timing.totalSeconds,seed:request.seed,frameIndex:request.frameIndex,input:request.input,previewGlow:request.previewGlow,assumptions:image.provenance.merging(["opticalProcessingScales":"glow=1/\(request.glowScale.rawValue); halation=1/\(request.halationScale.rawValue); softening=1/\(request.softeningScale.rawValue)","sourceNoise":"not estimated","domain":"linear exposure/WB/matrix; encoded LUT/tone/detail; linear softening/vignette/bloom/halation/resize; encoded sensor-noise/film-grain","clipping":"intentional at bounded LUT/non-neutral tone and final output; no intermediate color clamp"]){_,v in v},peakWorkingSetEstimateBytes:max(image.width*image.height,output.width*output.height)*16*8)
            return RenderResult(image:output,glowLayer:glowImage,manifest:manifest)
        }
    }
    /// Display-only GPU output. Owns a standalone packed texture, never a pooled lease.
    /// No CPU pixels are downloaded or validated; exports keep using render().
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
            let manifest=RenderManifest(profileDigest:profileDigest,effectiveDigest:style.effectiveDigest,inputDigest:inputDigest,lutDigest:resources.lut?.sha256 ?? "identity",device:device.name,quality:request.maximumLongEdge == nil ? "final":"preview",correctionDigest:lastWork.correctionDigest,width:output.width,height:output.height,timing:timing,seconds:timing.totalSeconds,seed:request.seed,frameIndex:request.frameIndex,input:request.input,previewGlow:request.previewGlow,
                assumptions:image.provenance.merging(["opticalProcessingScales":"glow=1/\(request.glowScale.rawValue); halation=1/\(request.halationScale.rawValue); softening=1/\(request.softeningScale.rawValue)","displayPath":"MTKView; GPU texture; no pixel readback","displayEncoding":"sRGB encoded; BGRA8 opaque; no additional transfer","domain":"linear exposure/WB/matrix; encoded LUT/tone/detail; linear softening/vignette/bloom/halation/resize; encoded sensor-noise/film-grain","clipping":"intentional at bounded LUT/non-neutral tone and final output; no intermediate color clamp"]){_,v in v},peakWorkingSetEstimateBytes:max(image.width*image.height,output.width*output.height)*16*8)
            return MetalPreviewFrame(texture:output,manifest:manifest)
        }
    }
    /// Candidate rendering plus compact patch statistics. Regions remain in original board coordinates.
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
    /// Own a bounded native-pixel ROI on GPU before the pooled render surface is recycled.
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
    /// Diagnostics only: render then read a compact GPU measurement, not a parameter fitter.
    public func renderFeatureStatistics(_ image:ImageFrame,style:ResolvedStyle,resources:RenderResources = .init(),request:RenderRequest,region:Region=Region(),kind:MeasurementKind) throws -> GPUFeatureStatistics {
        try renderReadback(image,style:style,resources:resources,request:request) {texture,_,command in
            try featureStatistics(texture,region:region,kind:kind,scale:1,renderCommand:command)
        }
    }
    /// Measure canonical input/reference pixels without applying any style or transfer round trip.
    public func measureFeatureStatistics(_ image:ImageFrame,region:Region=Region(),kind:MeasurementKind,scale:Double=1) throws -> GPUFeatureStatistics {
        try autoreleasepool {try measureFeatureStatisticsLocked(image,region:region,kind:kind,scale:scale)}
    }
    private func measureFeatureStatisticsLocked(_ image:ImageFrame,region:Region,kind:MeasurementKind,scale:Double) throws -> GPUFeatureStatistics {
        try image.validateStorage()
        lock.lock();defer{lock.unlock()};try Task.checkCancellation()
        let allocations=pool.allocations;lastWork=RenderWork()
        defer{trimCache();lastWork.allocations=pool.allocations-allocations}
        let key=image.pixels.withUnsafeBufferPointer{InputKey(address:UInt(bitPattern:$0.baseAddress!),width:image.width,height:image.height)}
        let entry=try input(image,key:key)
        if !entry.checkedSDR {
            guard image.pixels.allSatisfy({(0...1).contains($0)}) else {throw LabError.measurement("GPU 测量需要归一化的 SDR 图像，请先转换输入")}
            entry.checkedSDR=true
        }
        return try featureStatistics(entry.texture.texture,region:region,kind:kind,scale:scale,renderCommand:nil)
    }
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
            // Complete all effect writes before another command queue reads the texture.
            // The texture lease remains alive inside renderReadback until measurement finishes.
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
    private func complete(_ command:MTLCommandBuffer) throws {
        try Task.checkCancellation();command.commit();lastWork.submissions=1;command.waitUntilCompleted()
        if let error=command.error {throw error}
        // Read Metal's completed command timestamps, not CPU submission/wait duration.
        if command.gpuStartTime>0,command.gpuEndTime>=command.gpuStartTime {
            lastWork.gpuSeconds=command.gpuEndTime-command.gpuStartTime
        }
        try Task.checkCancellation()
    }
    private func renderReadback<T>(_ image:ImageFrame,style:ResolvedStyle,correction:DeviceCorrection? = nil,resources:RenderResources = .init(),request:RenderRequest,
                                   consume:(MTLTexture,MTLTexture?,MTLCommandBuffer)throws->T) throws -> T {
        try autoreleasepool {try renderLocked(image,style:style,correction:correction,resources:resources,request:request,consume:consume)}
    }
    private func renderLocked<T>(_ image:ImageFrame,style:ResolvedStyle,correction:DeviceCorrection?,resources:RenderResources,request:RenderRequest,
                                 consume:(MTLTexture,MTLTexture?,MTLCommandBuffer)throws->T) throws -> T {
        lock.lock();defer{lock.unlock()};try Task.checkCancellation()
        try request.validate();try image.descriptor.validate();try style.parameters.validate(resolved:true);try resources.validate()
        let preparedColor=try ColorTransform.prepare(style.parameters.color)
        guard request.input==image.descriptor,request.input.width==image.width,request.input.height==image.height,
              image.pixels.count==image.width*image.height*4 else {throw LabError.invalid("图像与输入声明不一致")}
        let allocations=pool.allocations
        lastWork=RenderWork();lastWork.preparationStarted=ProcessInfo.processInfo.systemUptime
        let correctionStart=ProcessInfo.processInfo.systemUptime
        let preparedCorrection:PreparedDeviceCorrection?
        if correction != nil || resources.correctionLUT != nil {
            let correctionKey=(try correction?.effectDigest() ?? "identity")+":"+(resources.correctionLUT?.sha256 ?? "identity")
            if let cached=correctionCache,cached.0==correctionKey {preparedCorrection=cached.1}
            else {
                if let asset=resources.correctionLUT {
                    if correctionLUTCache?.digest != asset.sha256 {correctionLUTCache=try PreparedLUT.prepare(asset,device:device)}
                } else {correctionLUTCache=nil}
                preparedCorrection=try PreparedDeviceCorrection.prepare(correction,preparedLUT:correctionLUTCache,device:device)
                correctionCache=(correctionKey,preparedCorrection)
            }
        } else {preparedCorrection=nil;correctionCache=nil}
        lastWork.correctionDigest=preparedCorrection?.digest ?? "identity"
        let bound=preparedCorrection?.color.maximumGain ?? 1
        let combined=max(bound,preparedColor.maximumGain*(preparedCorrection?.lutTexture == nil ? bound:1))
        guard combined.isFinite,combined < Double(Float.greatestFiniteMagnitude)/1024 else {throw LabError.invalid("组合颜色变换超出浮点安全范围")}
        if correction != nil || resources.correctionLUT != nil {lastWork.correctionSeconds=ProcessInfo.processInfo.systemUptime-correctionStart}
        let key=image.pixels.withUnsafeBufferPointer {InputKey(address:UInt(bitPattern:$0.baseAddress!),width:image.width,height:image.height,limit:request.maximumLongEdge,correctionDigest:preparedCorrection?.digest)}
        let maxSize=request.maximumLongEdge ?? max(image.width,image.height)
        pool.maximumReusableTextureBytes=min(pool.limit,maxSize*maxSize*16)
        // Avoid retaining multiple full-size photographs when switching source or resolution.
        inputs=inputs.filter{$0.key==key};pool.discardOversized()
        // A cancelled replacement must not invalidate previously completed input.
        // Newly encoded resize/correction/prefix textures are unsafe until submission
        // completes, so roll back to the last successful cache entry on any failure.
        let completedEntry=inputs[key],completedPrefix=inputs[key]?.prefix
        var succeeded=false
        defer {
            if !succeeded {
                if let completedEntry {
                    completedEntry.prefix=completedPrefix;inputs[key]=completedEntry
                } else {inputs.removeValue(forKey:key)}
            }
            command=nil;trimCache();lastWork.allocations=pool.allocations-allocations
        }
        guard let command=queue.makeCommandBuffer() else {throw LabError.io("无法创建图像处理任务")}
        self.command=command;command.label="Lumera desktop Float32 effects"
        if inputs[key]?.checkedRenderInput != true {
            guard image.pixels.enumerated().allSatisfy({$0.element.isFinite && ($0.offset%4==3 ? $0.element==1:(0...1).contains($0.element))}) else {
                throw LabError.invalid("渲染输入需要不透明、0–1 范围的 SDR 成片像素")
            }
        }
        let entry=try input(image,key:key,correction:preparedCorrection);entry.checkedRenderInput=true
        lastWork.inputPrepared=ProcessInfo.processInfo.systemUptime
        let p=style.parameters,scale=EffectScale.factor(width:entry.texture.width,height:entry.texture.height)
        let prefixKey=PrefixKey(parameters:p,lut:resources.lut?.sha256,previewGlow:request.previewGlow,glowScale:request.glowScale,halationScale:request.halationScale,softeningScale:request.softeningScale)
        var current=entry.texture
        let active=preparedCorrection != nil || p.color.isActive || resources.lut != nil || p.tone.isActive || p.detail.isActive || p.softening.isActive || p.vignette.isActive || (request.previewGlow && (p.glow.isActive || p.halation.isActive)) || p.noise.isActive || p.grain.isActive
        if !active {
            let result=try consume(current.texture,nil,command);succeeded=true;return result
        }
        if let prefix=entry.prefix,prefix.key==prefixKey {current=prefix.image;lastWork.prefixHits=1}
        else {
            entry.prefix=nil
            if p.color.isActive {current=try pass("colorResponse",current,[],preparedColor.uniforms)}
            current=try applyLUT(current,resources.lut)
            if p.tone.isActive {current=try pass("toneResponse",current,[],CameraEffectUniforms.tone(p.tone))}
            current=try detail(current,p.detail,scale)
            current=try pass("transfer",current,[],[-1])
            if p.softening.isActive {
                let geometry=try OpticalProcessingGeometry(width:current.width,height:current.height,scale:request.softeningScale.scale)
                let reduced=request.softeningScale != .full
                let base=reduced ? try pass("opticalReduce",current,[],[0,0,0],size:(geometry.width,geometry.height)):current
                let blurred=try blur(base,sigma:p.softening.sigma*scale,scaleX:geometry.scaleX,scaleY:geometry.scaleY)
                current=try pass(reduced ? "softenCombineReduced":"softenCombine",current,[blurred],[Float(p.softening.amount)])
            }
            let v=p.vignette
            if v.isActive {current=try pass("vignette",current,[],[Float(v.amountEV),Float(v.startRadius),Float(v.falloff),Float(v.centerX),Float(v.centerY)])}
            if request.previewGlow {
                if p.glow.isActive,request.glowScale != .full {
                    let g=p.glow,geometry=try OpticalProcessingGeometry(width:current.width,height:current.height,scale:request.glowScale.scale)
                    let hi=try pass("opticalReduce",current,[],[1,Float(g.threshold),Float(g.knee)],size:(geometry.width,geometry.height))
                    let near=try blur(hi,sigma:g.nearSigma*scale,scaleX:geometry.scaleX,scaleY:geometry.scaleY)
                    let far=try blur(hi,sigma:g.farSigma*scale,scaleX:geometry.scaleX,scaleY:geometry.scaleY)
                    current=try pass("glowCombineReduced",current,[near,far],[Float(g.amount),Float(g.farWeight),Float(g.threshold),Float(g.knee)])
                }else{(current,_)=try glow(current,p.glow,scale,includeLayer:false)}
                if p.halation.isActive {
                    let h=p.halation,geometry=try OpticalProcessingGeometry(width:current.width,height:current.height,scale:request.halationScale.scale)
                    let reduced=request.halationScale != .full
                    let hi=reduced ? try pass("opticalReduce",current,[],[1,Float(h.threshold),Float(h.knee)],size:(geometry.width,geometry.height)):try pass("highlights",current,[],[Float(h.threshold),Float(h.knee)])
                    let scattered=try blur(hi,sigma:h.sigma*scale,scaleX:geometry.scaleX,scaleY:geometry.scaleY)
                    current=reduced ? try pass("halationCombineReduced",current,[scattered],CameraEffectUniforms.halation(h)+[Float(h.threshold),Float(h.knee)]):try pass("halationCombine",current,[hi,scattered],CameraEffectUniforms.halation(h))
                }
            }
            entry.prefix=CachedPrefix(key:prefixKey,image:current,layer:nil)
        }
        let n=p.noise,noiseOn=n.isActive
        var luma=current,chroma=current
        if noiseOn {
            let random=try pass("randomField",current,[],[Float(bitPattern:style.temporalPolicy.noise.seed(request.seed,frameIndex:request.frameIndex))])
            luma=try blur(random,sigma:n.lumaSigma*scale,noise:true);chroma=try blur(random,sigma:n.chromaSigma*scale,noise:true)
        }
        current=try pass("finish",current,[luma,chroma],CameraEffectUniforms.noise(n))
        if p.grain.isActive {current=try pass("filmGrain",current,[],CameraEffectUniforms.grain(p.grain,scale:scale,seed:request.seed,frameIndex:style.temporalPolicy.grain == .fixed ? 0:request.frameIndex))}
        try Task.checkCancellation()
        let result=try consume(current.texture,nil,command);succeeded=true;return result
    }
}

/// Per-call work counters for performance regression checks (not a UI progress estimate).
struct RenderWork {
    var preparationStarted=0.0,inputPrepared=0.0,correctionSeconds=0.0
    var correctionDispatches=0
    var correctionDigest="identity"
    var gpuSeconds:Double? = nil
    var uploads=0,allocations=0,dispatches=0,submissions=0,prefixHits=0,readbackBytes=0
}
private struct InputKey:Hashable {let address:UInt;let width:Int,height:Int;var limit:Int?=nil;var correctionDigest:String?=nil}
private final class CachedInput {
    let pixels:[Float],texture:TextureLease
    var lastUse:UInt64
    var checkedSDR=false
    var checkedRenderInput=false
    var prefix:CachedPrefix?
    init(pixels:[Float],texture:TextureLease,lastUse:UInt64) {self.pixels=pixels;self.texture=texture;self.lastUse=lastUse}
    var byteCount:Int {
        var unique=[ObjectIdentifier(texture):texture]
        if let prefix {unique[ObjectIdentifier(prefix.image)]=prefix.image;if let layer=prefix.layer{unique[ObjectIdentifier(layer)]=layer}}
        return unique.values.reduce(0){$0+$1.width*$1.height*16}
    }
}
private struct CachedPrefix {let key:PrefixKey;let image:TextureLease;let layer:TextureLease?}
private struct PrefixKey:Equatable {
    let color:ColorResponse,tone:ToneResponse,detail:Detail,softening:Softening,vignette:Vignette,glow:Glow,halation:Halation
    let lut:String?,previewGlow:Bool
    let glowScale:EffectResolution,halationScale:EffectResolution,softeningScale:EffectResolution
    init(parameters p:StyleParameters,lut:String?,previewGlow:Bool,glowScale:EffectResolution,halationScale:EffectResolution,softeningScale:EffectResolution) {
        self.glowScale=glowScale;self.halationScale=halationScale;self.softeningScale=softeningScale
        color=p.color;tone=p.tone;detail=p.detail;softening=p.softening;vignette=p.vignette
        glow=p.glow;halation=p.halation;self.lut=lut;self.previewGlow=previewGlow
    }
}
// Leases cannot be recycled while a source, prefix or later pass still references them.
// Metal's default hazard tracking protects earlier encoded readers when storage is reused.
private final class TextureLease {
    let texture:MTLTexture
    let pool:TexturePool
    var width:Int {texture.width};var height:Int {texture.height}
    init(_ texture:MTLTexture,pool:TexturePool){self.texture=texture;self.pool=pool}
    deinit {pool.recycle(texture)}
}
private final class TexturePool {
    let device:MTLDevice,limit:Int
    var available:[MTLTexture]=[]
    var bytes=0,allocations=0
    var maximumReusableTextureBytes=Int.max
    func removeAll(){available.removeAll();bytes=0}
    func discardOversized(){available.removeAll{$0.width*$0.height*16>maximumReusableTextureBytes};bytes=available.reduce(0){$0+$1.width*$1.height*16}}
    init(device:MTLDevice,limit:Int){self.device=device;self.limit=limit}
    func take(_ width:Int,_ height:Int) throws -> TextureLease {
        try TextureDimensions.validate(width:width,height:height,device:device)
        if let i=available.firstIndex(where:{$0.width==width && $0.height==height}) {
            let texture=available.remove(at:i);bytes-=width*height*16
            return TextureLease(texture,pool:self)
        }
        let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba32Float,width:width,height:height,mipmapped:false)
        d.storageMode = .shared;d.usage = [.shaderRead,.shaderWrite];d.hazardTrackingMode = .tracked
        guard let texture=device.makeTexture(descriptor:d) else {throw LabError.io("图像处理内存不足，请使用较小照片或关闭其他占用内存的应用后重试")}
        allocations+=1;return TextureLease(texture,pool:self)
    }
    func recycle(_ texture:MTLTexture) {
        let size=texture.width*texture.height*16
        guard size<=limit,size<=maximumReusableTextureBytes else{return}
        while bytes+size>limit,!available.isEmpty {let removed=available.removeFirst();bytes-=removed.width*removed.height*16}
        available.append(texture);bytes+=size
    }
}

/// Completed immutable display texture; retaining this value keeps pixels valid across later renders.
public final class MetalPreviewFrame: @unchecked Sendable {
    public let texture:MTLTexture
    public let manifest:RenderManifest
    fileprivate init(texture:MTLTexture,manifest:RenderManifest) {self.texture=texture;self.manifest=manifest}
}
