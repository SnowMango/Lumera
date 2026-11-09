import Foundation
import Metal
import ImagingCore

private struct ReferencePixels {
    let pixels:[Float]
    let descriptor:InputDescriptor
    var width:Int { descriptor.width }
    var height:Int { descriptor.height }
}
/// 以 Float32 存储执行参考效果。缓存和工作统计由调用方串行访问。
package final class ReferenceRenderSession {
    let device:MTLDevice, queue:MTLCommandQueue
    var pipelines:[String:MTLComputePipelineState]=[:]
    var materialPipeline:MTLComputePipelineState?
    let pool:TexturePool
    var command:MTLCommandBuffer?
    var inputs:[InputKey:CachedInput]=[:]
    var lastUse:UInt64=0
    var gaussianWeights:[UInt64:(PreparedGaussianKernel,MTLBuffer)]=[:]
    var correctionCache:(String,PreparedDeviceCorrection?)?
    var correctionLUTCache:PreparedLUT?
    var lutCache:(String,MTLTexture)?
    private var executionPlan:PreparedExecutionPlan?
    let cacheLimitBytes:Int
    package var lastWork=ReferenceRenderWork()
    package var cachedBytes:Int { inputs.values.reduce(0) { $0+$1.byteCount } }
    package var pooledBytes:Int { pool.bytes }
    package var cachedInputCount:Int { inputs.count }
    package init(device:MTLDevice,cacheLimitBytes requested:Int?=nil)throws {
        guard let queue=device.makeCommandQueue() else {throw LabError.noMetal}
        self.device=device;self.queue=queue
        let recommended=Int(min(UInt64(1_073_741_824),device.recommendedMaxWorkingSetSize/4))
        if let requested,requested<0 {throw LabError.invalid("纹理缓存预算不能为负数")}
        cacheLimitBytes=min(recommended,requested ?? recommended)
        pool=TexturePool(device:device,limit:min(536_870_912,cacheLimitBytes/2))
        let library=try RenderingResources.makeLibrary(device:device)
        for name in ["weightedLUTMap","lutMapExtrapolated","transfer","lutMap","gaussianPrepared","detailCombine","sharpen","vignette","highlights","glowCombine","resizeLinear","randomField","finish"] + CameraEffectUniforms.kernels {
            guard let f=library.makeFunction(name:name) else {throw LabError.io("缺少图像处理函数： \(name)")}
            pipelines[name]=try device.makeComputePipelineState(function:f)
        }
    }
    package func releaseCaches() {
        executionPlan=nil;inputs.removeAll();lutCache=nil;correctionCache=nil;correctionLUTCache=nil;gaussianWeights.removeAll();pool.removeAll()
    }
    package func prepareReferencePixels(_ pixels:[Float],descriptor:InputDescriptor) throws -> [Float]? {
        let image=ReferencePixels(pixels:pixels,descriptor:descriptor)
        try Task.checkCancellation()
        let allocations=pool.allocations;lastWork=ReferenceRenderWork()
        defer{trimCache();lastWork.allocations=pool.allocations-allocations}
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
            return nil
        }
        let normalized=download(output.texture)
        try Task.checkCancellation()
        let key=normalized.withUnsafeBufferPointer{InputKey(address:UInt(bitPattern:$0.baseAddress!),width:image.width,height:image.height)}
        lastUse &+= 1
        let entry=CachedInput(pixels:normalized,texture:output,lastUse:lastUse);entry.checkedSDR=true
        inputs[key]=entry
        return normalized
    }
    private func input(_ image:ReferencePixels,key:InputKey,prepare:((TextureLease)throws->TextureLease)? = nil) throws -> CachedInput {
        lastUse &+= 1
        if let entry=inputs[key] {entry.lastUse=lastUse;return entry}
        var texture=try pool.take(image.width,image.height)
        image.pixels.withUnsafeBytes {texture.texture.replace(region:MTLRegionMake2D(0,0,image.width,image.height),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:image.width*16)}
        lastWork.uploads+=1
        if let prepare { texture=try prepare(texture) }
        // Retaining the array makes its storage identity safe: mutations must copy it.
        let entry=CachedInput(pixels:image.pixels,texture:texture,lastUse:lastUse)
        inputs[key]=entry;return entry
    }
    private func trimCache() {
        while cachedBytes>cacheLimitBytes,let oldest=inputs.min(by:{$0.value.lastUse<$1.value.lastUse})?.key {
            inputs.removeValue(forKey:oldest)
        }
    }
    func download(_ texture:MTLTexture) -> [Float] {
        lastWork.readbackBytes += texture.width*texture.height*16
        var floats=[Float](repeating:0,count:texture.width*texture.height*4)
        floats.withUnsafeMutableBytes {texture.getBytes($0.baseAddress!,bytesPerRow:texture.width*16,from:MTLRegionMake2D(0,0,texture.width,texture.height),mipmapLevel:0)}
        return floats
    }
    func pass(_ name:String,_ input:TextureLease,_ extra:[TextureLease]=[],_ params:[Float]=[0],size:(Int,Int)?=nil,lut:MTLTexture?=nil,weights:MTLBuffer?=nil,lutTextures:[MTLTexture]=[]) throws -> TextureLease {
        try Task.checkCancellation()
        let out=try pool.take(size?.0 ?? input.width,size?.1 ?? input.height)
        guard let pipeline=pipelines[name],let encoder=command?.makeComputeCommandEncoder() else {throw LabError.io("无法创建图像处理任务，请重试")}
        encoder.setComputePipelineState(pipeline);encoder.setTexture(input.texture,index:0);encoder.setTexture(out.texture,index:1)
        for (i,t) in extra.enumerated(){encoder.setTexture(t.texture,index:i+2)}
        if let lut {encoder.setTexture(lut,index:2)}
        for (i, texture) in lutTextures.enumerated() { encoder.setTexture(texture, index: i + 2) }
        if let weights {encoder.setBuffer(weights,offset:0,index:1)}
        params.withUnsafeBytes{encoder.setBytes($0.baseAddress!,length:$0.count,index:0)}
        encoder.dispatchThreads(MTLSize(width:out.width,height:out.height,depth:1),threadsPerThreadgroup:MTLSize(width:16,height:16,depth:1))
        // Tracked textures order dependencies between encoders, including recycled scratch textures.
        encoder.endEncoding();lastWork.dispatches+=1;return out
    }
    func blur(_ input:TextureLease,sigma:Double,noise:Bool=false,scaleX:Double=1,scaleY:Double=1,integrated:Bool=false) throws -> TextureLease {
        func axis(_ source:TextureLease,_ radius:Double,_ direction:Float) throws -> TextureLease {
            if !integrated && radius<0.08{return source}
            let key=UInt64(Float(radius).bitPattern)*4+(integrated ? 2 : (noise ? 1 : 0))
            let cached:(PreparedGaussianKernel,MTLBuffer)
            if let existing=gaussianWeights[key] {cached=existing}
            else {
                if gaussianWeights.count>=32 {gaussianWeights.removeAll(keepingCapacity:true)}
                let kernel=try PreparedGaussianKernel(sigma:Float(radius),noise:noise,integrated:integrated)
                guard let buffer=kernel.weights.withUnsafeBytes({device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared)}) else {throw LabError.io("无法分配模糊权重")}
                cached=(kernel,buffer);gaussianWeights[key]=cached
            }
            return try pass("gaussianPrepared",source,[],[Float(cached.0.radius),direction,cached.0.denominator,noise ? 1:0],weights:cached.1)
        }
        return try axis(axis(input,sigma*scaleX,0),sigma*scaleY,1)
    }
    private func preparedLUT(_ ref:LUTAsset?) throws -> MTLTexture? {
        guard let ref else{return nil}
        if let cached=lutCache,cached.0==ref.sha256 {return cached.1}
        let cube=try ref.decodedCube()
        let d=MTLTextureDescriptor();d.textureType = .type3D;d.pixelFormat = .rgba32Float;d.width=cube.size;d.height=cube.size;d.depth=cube.size;d.storageMode = .shared;d.usage = .shaderRead
        guard let t=device.makeTexture(descriptor:d) else {throw LabError.io("无法为 LUT 分配内存，请重试或使用较小尺寸的 LUT")}
        cube.rgba.withUnsafeBytes{t.replace(region:MTLRegionMake3D(0,0,0,cube.size,cube.size,cube.size),mipmapLevel:0,slice:0,withBytes:$0.baseAddress!,bytesPerRow:cube.size*16,bytesPerImage:cube.size*cube.size*16)}
        lutCache=(ref.sha256,t)
        return t
    }
    package func complete(_ command:MTLCommandBuffer) throws {
        try Task.checkCancellation();command.commit();lastWork.submissions=1;command.waitUntilCompleted()
        if let error=command.error {throw error}
        // Read Metal's completed command timestamps, not CPU submission/wait duration.
        if command.gpuStartTime>0,command.gpuEndTime>=command.gpuStartTime {
            lastWork.gpuSeconds=command.gpuEndTime-command.gpuStartTime
        }
        try Task.checkCancellation()
    }
    /// 编码参考渲染后将借用纹理和命令交给回调，由回调提交并等待成功完成后再返回。
    package func withRenderedTexture<T>(pixels:[Float],style:ResolvedStyle,correction:DeviceCorrection?,resources:RenderResources,request:RenderRequest,
                                 consume:(MTLTexture,MTLCommandBuffer)throws->T) throws -> T {
        let image=ReferencePixels(pixels:pixels,descriptor:request.input)
        try Task.checkCancellation()
        try request.validate();try image.descriptor.validate();try style.parameters.validate(resolved:true);try resources.validate()
        guard request.dynamicRange == .sdr else {
            throw LabError.unsupported("离线标定/分析渲染只支持 SDR；EDR 请使用 LumeraRenderer 或 TextureEffectEncoder")
        }
        let preparedColor=try ColorTransform.prepare(style.parameters.color)
        guard request.input==image.descriptor,request.input.width==image.width,request.input.height==image.height,
              image.pixels.count==image.width*image.height*4 else {throw LabError.invalid("图像与输入声明不一致")}
        let allocations=pool.allocations
        lastWork=ReferenceRenderWork();lastWork.preparationStarted=ProcessInfo.processInfo.systemUptime
        let correctionStart=ProcessInfo.processInfo.systemUptime
        let preparedCorrection:PreparedDeviceCorrection?
        if correction != nil || resources.correctionLUT != nil {
            let correctionKey=(try correction?.effectDigest() ?? "identity")+":"+(resources.correctionLUT.map { $0.sha256+":"+$0.boundaryPolicy.rawValue } ?? "identity")
            if let cached=correctionCache,cached.0==correctionKey {preparedCorrection=cached.1}
            else {
                if let asset=resources.correctionLUT {
                    if correctionLUTCache?.digest != asset.sha256 || correctionLUTCache?.boundaryPolicy != asset.boundaryPolicy {correctionLUTCache=try PreparedLUT.prepare(asset,device:device)}
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
        // 缩放、校正和前缀结果须在提交成功后才可缓存。失败时回退至上次完成的条目。
        let completedEntry=inputs[key],completedPrefix=inputs[key]?.prefix
        var succeeded=false
        defer {
            if !succeeded {
                if let completedEntry {
                    completedEntry.prefix=completedPrefix;inputs[key]=completedEntry
                } else {inputs.removeValue(forKey:key)}
            }
            if let pending=self.command, pending.status == .committed || pending.status == .scheduled { pending.waitUntilCompleted() }
            command=nil;trimCache();lastWork.allocations=pool.allocations-allocations
        }
        guard let command=queue.makeCommandBuffer() else {throw LabError.io("无法创建图像处理任务")}
        self.command=command;command.label="Lumera desktop Float32 effects"
        if inputs[key]?.checkedRenderInput != true {
            guard image.pixels.enumerated().allSatisfy({$0.element.isFinite && ($0.offset%4==3 ? $0.element==1:(0...1).contains($0.element))}) else {
                throw LabError.invalid("渲染输入需要不透明、0–1 范围的 SDR 成片像素")
            }
        }
        let p=style.parameters
        let limit=min(request.maximumLongEdge ?? max(image.width,image.height),max(image.width,image.height))
        let ratio=Double(limit)/Double(max(image.width,image.height))
        let width=max(1,Int(Double(image.width)*ratio)),height=max(1,Int(Double(image.height)*ratio))
        let geometry=RenderGeometry(fullWidth:width,fullHeight:height,area:CGRect(x:0,y:0,width:width,height:height),sourceWidth:image.width,sourceHeight:image.height,sourceArea:CGRect(x:0,y:0,width:image.width,height:image.height))
        if executionPlan == nil { executionPlan=PreparedExecutionPlan(parameters:p,color:preparedColor) }
        let frame=EffectFrame(executionPlan:executionPlan!,parameters:p,color:preparedColor,curves:PreparedResponseCurves(p),lut:try preparedLUT(resources.lut),lutBoundaryPolicy:resources.lut?.boundaryPolicy ?? .automatic,correction:preparedCorrection,temporal:style.temporalPolicy,request:request,geometry:geometry)
        let backend=ReferenceEffectBackend(session:self)
        let pipeline=EffectPipeline(backend:backend,frame:frame)
        let entry=try input(image,key:key) { source in
            try pipeline.prepareInput(source)
        }
        entry.checkedRenderInput=true
        lastWork.inputPrepared=ProcessInfo.processInfo.systemUptime
        let prefixKey=PrefixKey(parameters:p,lut:resources.lut.map { $0.sha256+":"+$0.boundaryPolicy.rawValue },previewGlow:request.previewGlow,glowScale:request.glowScale,halationScale:request.halationScale,softeningScale:request.softeningScale)
        var current=entry.texture
        let active=preparedCorrection != nil || p.color.isActive || resources.lut != nil || p.tone.isActive || p.detail.isActive || p.softening.isActive || p.vignette.isActive || (request.previewGlow && (p.glow.isActive || p.halation.isActive)) || p.noise.isActive || p.grain.isActive
        if !active {
            let result=try consume(current.texture,command);guard command.status == .completed, command.error == nil else { throw LabError.io("参考纹理消费者必须等待 GPU 完成") };succeeded=true;return result
        }
        if let prefix=entry.prefix,prefix.key==prefixKey {current=prefix.image;lastWork.prefixHits=1}
        else {
            current=try pipeline.encodePrefix(current)
            entry.prefix=CachedPrefix(key:prefixKey,image:current,layer:nil)
        }
        current=try pipeline.encodeSuffix(current)
        try Task.checkCancellation()
        let result=try consume(current.texture,command);guard command.status == .completed, command.error == nil else { throw LabError.io("参考纹理消费者必须等待 GPU 完成") };succeeded=true;return result
    }
    /// 借用参考输入纹理，租约由会话管理，回调内完成消费。
    package func withInputTexture<T>(pixels:[Float],descriptor:InputDescriptor,consume:(MTLTexture)throws->T) throws -> T {
        let image=ReferencePixels(pixels:pixels,descriptor:descriptor)
        try Task.checkCancellation()
        let allocations=pool.allocations;lastWork=ReferenceRenderWork()
        defer{trimCache();lastWork.allocations=pool.allocations-allocations}
        let key=pixels.withUnsafeBufferPointer{InputKey(address:UInt(bitPattern:$0.baseAddress!),width:image.width,height:image.height)}
        let entry=try input(image,key:key)
        if !entry.checkedSDR {
            guard pixels.allSatisfy({(0...1).contains($0)}) else {throw LabError.measurement("GPU 测量需要归一化的 SDR 图像，请先转换输入")}
            entry.checkedSDR=true
        }
        return try consume(entry.texture.texture)
    }
}

package struct ReferenceRenderWork {
    package var preparationStarted=0.0,inputPrepared=0.0,correctionSeconds=0.0
    package var correctionDispatches=0
    package var correctionDigest="identity"
    package var gpuSeconds:Double? = nil
    package var uploads=0,allocations=0,dispatches=0,submissions=0,prefixHits=0,readbackBytes=0
}
