import Foundation
import Metal
import ImagingCore

/// Immutable, validated snapshot. LUT upload and parsing happen once, outside the frame loop.
public final class PreparedCameraStyle: @unchecked Sendable {
    public let style: ResolvedStyle
    fileprivate let curves:PreparedResponseCurves
    fileprivate let color: PreparedColorTransform
    fileprivate let lut: MTLTexture?
    fileprivate let deviceID: UInt64
    fileprivate init(style: ResolvedStyle, color:PreparedColorTransform, lut: MTLTexture?, deviceID: UInt64) {
        self.curves=PreparedResponseCurves(style.parameters);self.style=style; self.color=color; self.lut=lut; self.deviceID=deviceID
    }
}

/// Encodes the CCDLab SDR pipeline into the caller's command buffer without submitting or waiting.
/// Consume the returned texture in that same command buffer; scratch storage is recycled after completion.
public final class TextureEffectEncoder: @unchecked Sendable {
    private let device: MTLDevice
    private let pipelines: [String: MTLComputePipelineState]
    private let poolLock=NSLock()
    private var available: [Arena]=[]
    private var cacheGeneration:UInt64=0
    private var lutParses=0,lutUploads=0
    private let lutLock=NSLock()
    private var preparedLUTs:[PreparedLUT]=[]
    public var staticResourceStatistics:StaticResourceStatistics {
        poolLock.lock();defer{poolLock.unlock()}
        return StaticResourceStatistics(lutParses:lutParses,lutUploads:lutUploads)
    }
    /// Idle cached resources only, excluding in-flight work and caller-owned prepared LUTs.
    public var cacheStatistics:RenderCacheStatistics {
        poolLock.lock();defer{poolLock.unlock()}
        return RenderCacheStatistics(kernelCount:available.reduce(0){$0+$1.kernelCount},textureBytes:available.reduce(0){$0+$1.byteCount},kernelBytes:available.reduce(0){$0+$1.kernelBytes})
    }
    private let precision:RenderingPrecision
    private let cacheByteLimit=256*1024*1024
    public var cachedTextureBytes:Int {
        poolLock.lock();defer{poolLock.unlock()};return available.reduce(0){$0+$1.byteCount}
    }
    /// Drop idle scratch storage now, and prevent pre-release in-flight arenas rejoining the cache.
    public func releaseCaches() {
        lutLock.lock();preparedLUTs.removeAll();lutLock.unlock()
        poolLock.lock();defer{poolLock.unlock()};available.removeAll();cacheGeneration &+= 1
    }


    public init(device: MTLDevice, precision:RenderingPrecision = .float16) throws {
        self.device=device;self.precision=precision
        let library=try RenderingResources.makeLibrary(device:device)
        var compiled=[String:MTLComputePipelineState]()
        for name in ["transfer","lutMap","gaussianPrepared","detailCombine","sharpen","vignette","highlights","glowCombine","resizeLinear","randomField","finish"] + CameraEffectUniforms.kernels {
            guard let function=library.makeFunction(name:name) else {throw LabError.io("缺少 风格处理函数："+name)}
            compiled[name]=try device.makeComputePipelineState(function:function)
        }
        pipelines=compiled
    }

    private func prepareLUT(_ asset:LUTAsset?) throws -> PreparedLUT? {
        guard let asset else{return nil};try asset.validate()
        lutLock.lock();defer{lutLock.unlock()}
        if let index=preparedLUTs.firstIndex(where:{$0.digest==asset.sha256}) {
            let cached=preparedLUTs.remove(at:index);preparedLUTs.append(cached);return cached
        }
        let prepared=try PreparedLUT.prepare(asset,device:device)
        poolLock.lock();lutParses+=1;lutUploads+=1;poolLock.unlock()
        // One creative LUT and one correction LUT; prepared snapshots own in-flight resources.
        preparedLUTs.append(prepared);if preparedLUTs.count>2 {preparedLUTs.removeFirst()}
        return prepared
    }
    public func prepare(_ style:ResolvedStyle,lut:LUTAsset?=nil) throws -> PreparedCameraStyle {
        try style.parameters.validate(resolved:true)
        return PreparedCameraStyle(style:style,color:try ColorTransform.prepare(style.parameters.color),lut:try prepareLUT(lut)?.texture,deviceID:device.registryID)
    }

    public func prepareCorrection(_ correction:DeviceCorrection?,lut:LUTAsset?=nil) throws -> PreparedDeviceCorrection? {
        try PreparedDeviceCorrection.prepare(correction,preparedLUT:prepareLUT(lut),device:device)
    }

    public func encode(_ input: MTLTexture, style: PreparedCameraStyle, correction:PreparedDeviceCorrection? = nil, request:RenderRequest,
                       commandBuffer: MTLCommandBuffer) throws -> MTLTexture {
        try encodeFrame(input,parameters:style.style.parameters,color:style.color,curves:style.curves,lut:style.lut,styleDeviceID:style.deviceID,
                        temporal:style.style.temporalPolicy,correction:correction,request:request,commandBuffer:commandBuffer)
    }
    public func prepare(_ definition:CompiledStyleDefinition,lut:LUTAsset?=nil) throws -> PreparedStyleDefinition {
        let fixed=try prepare(ResolvedStyle(parameters:definition.parameters,profileDigest:definition.identity,temporalPolicy:definition.temporalPolicy),lut:lut)
        return PreparedStyleDefinition(definition:definition,fixed:fixed)
    }
    public func encode(_ input:MTLTexture,style:PreparedStyleDefinition,parameters:FrameStyleParameters,
                       correction:PreparedDeviceCorrection?=nil,request:RenderRequest,commandBuffer:MTLCommandBuffer) throws -> MTLTexture {
        let values=parameters.evaluated
        guard values.definitionIdentity==style.definition.identity else {throw LabError.invalid("帧参数不属于此已准备风格定义")}
        return try encodeFrame(input,parameters:values.parameters,color:ColorTransform.prepare(values.parameters.color),
                               curves:style.fixed.curves,lut:style.fixed.lut,styleDeviceID:style.fixed.deviceID,temporal:values.temporalPolicy,
                               correction:correction,request:request,commandBuffer:commandBuffer)
    }
    private func encodeFrame(_ input:MTLTexture,parameters p:StyleParameters,color:PreparedColorTransform,curves:PreparedResponseCurves,lut:MTLTexture?,
                             styleDeviceID:UInt64,temporal:TemporalPolicy,correction:PreparedDeviceCorrection?,
                             request:RenderRequest,commandBuffer:MTLCommandBuffer) throws -> MTLTexture {
        try request.validate()
        guard input.device.registryID==device.registryID, styleDeviceID==device.registryID,
              correction == nil || correction!.deviceID==device.registryID,
              commandBuffer.device.registryID==device.registryID, commandBuffer.status == .notEnqueued,
              commandBuffer.retainedReferences,
              input.textureType == .type2D, input.width==request.input.width,input.height==request.input.height,
              [.rgba8Unorm,.bgra8Unorm,.rgba16Float,.rgba32Float].contains(input.pixelFormat) else {
            throw LabError.invalid("纹理尺寸、格式或设备与请求不符；请传入保留资源引用且尚未提交的 command buffer")
        }
        let maximumLongEdge=request.maximumLongEdge
        let hasEffects=correction != nil || p.color.isActive || lut != nil || p.tone.isActive || p.detail.isActive || p.softening.isActive || p.vignette.isActive || (request.previewGlow && (p.glow.isActive || p.halation.isActive)) || p.noise.isActive || p.grain.isActive
        if !hasEffects,maximumLongEdge == nil || maximumLongEdge!>=max(input.width,input.height) {return input}
        // An extreme but valid white-point transform can exceed half-float optical intermediates.
        // Conservative row-sum bound leaves headroom for detail and diffusion; use Float32 then.
        let colorBound=color.maximumGain
        let correctionBound=correction?.color.maximumGain ?? 1
        let combinedBound=max(correctionBound,colorBound*(correction?.lutTexture == nil ? correctionBound:1))
        guard combinedBound.isFinite,combinedBound < Double(Float.greatestFiniteMagnitude)/1024 else {throw LabError.invalid("组合颜色变换超出浮点安全范围")}
        let format:MTLPixelFormat=(precision == .float32 || combinedBound>256) ? .rgba32Float:.rgba16Float
        poolLock.lock()
        let arena=available.popLast() ?? Arena(device:device)
        let generation=cacheGeneration
        poolLock.unlock()
        arena.configure(width:input.width,height:input.height,limit:maximumLongEdge,format:format)
        // Resources remain reserved until completion even if encoding throws after its first pass.
        commandBuffer.addCompletedHandler { [weak self,arena] command in
            if command.status == .error {arena.clearNoise()}
            self?.recycle(arena,generation:generation)
        }
        if !p.noise.isActive {arena.clearNoise()}
        func pass(_ name:String,_ source:MTLTexture,_ extras:[MTLTexture]=[],_ parameters:[Float]=[0],size:(Int,Int)?=nil,weights:MTLBuffer?=nil) throws -> MTLTexture {
            let result=try arena.take(width:size?.0 ?? source.width,height:size?.1 ?? source.height)
            guard let state=pipelines[name],let encoder=commandBuffer.makeComputeCommandEncoder() else {throw LabError.io("无法创建 风格渲染 GPU 任务")}
            encoder.setComputePipelineState(state)
            encoder.setTexture(source,index:0);encoder.setTexture(result,index:1)
            for (i,texture) in extras.enumerated(){encoder.setTexture(texture,index:i+2)}
            parameters.withUnsafeBytes{encoder.setBytes($0.baseAddress!,length:$0.count,index:0)}
            if let weights {encoder.setBuffer(weights,offset:0,index:1)}
            encoder.dispatchThreads(MTLSize(width:result.width,height:result.height,depth:1),threadsPerThreadgroup:MTLSize(width:16,height:16,depth:1))
            encoder.endEncoding();return result
        }
        func blur(_ source:MTLTexture,_ sigma:Double,noise:Bool=false,scaleX:Double=1,scaleY:Double=1) throws -> MTLTexture {
            func axis(_ input:MTLTexture,_ radius:Double,_ direction:Float) throws -> MTLTexture {
                if radius<0.08{return input}
                let (kernel,weights)=try arena.kernel(sigma:Float(radius),noise:noise)
                return try pass("gaussianPrepared",input,[],[Float(kernel.radius),direction,kernel.denominator,noise ? 1:0],weights:weights)
            }
            let x=try axis(source,sigma*scaleX,0),y=try axis(x,sigma*scaleY,1)
            if x !== source && x !== y {arena.release(x)}
            return y
        }
        var current=input
        if let correction {
            if correction.colorIsActive {current=try pass("colorResponse",current,[],correction.color.uniforms)}
            if let lut=correction.lutTexture {let next=try pass("lutMap",current,[lut]);arena.release(current);current=next}
        }
        if let limit=maximumLongEdge,max(current.width,current.height)>limit {
            let ratio=Double(limit)/Double(max(current.width,current.height))
            let linear=try pass("transfer",current,[],[-1])
            arena.release(current)
            let scaled=try pass("resizeLinear",linear,size:(max(1,Int(Double(current.width)*ratio)),max(1,Int(Double(current.height)*ratio))))
            arena.release(linear)
            current=try pass("transfer",scaled,[],[1]);arena.release(scaled)
        }
        let scale=EffectScale.factor(width:current.width,height:current.height)
        if p.color.isActive {let next=try pass("colorResponse",current,[],color.uniforms);arena.release(current);current=next}
        if let lut {let next=try pass("lutMap",current,[lut]);arena.release(current);current=next}
        if p.tone.isActive {let next=try pass("toneResponse",current,[],curves.tone);arena.release(current);current=next}
        if p.detail.isActive {
            let fine=try blur(current,p.detail.fineSigma*scale),mid=try blur(current,p.detail.midSigma*scale)
            let next=try pass("detailCombine",current,[fine,mid],[Float(p.detail.fineGain),Float(p.detail.midGain)])
            arena.release(fine);arena.release(mid);arena.release(current);current=next
            if p.detail.sharpenAmount>0 {
                let blurred=try blur(current,p.detail.sharpenSigma*scale)
                let next=try pass("sharpen",current,[blurred],[Float(p.detail.sharpenAmount),Float(p.detail.threshold),Float(p.detail.maxAdjustment)])
                arena.release(blurred);arena.release(current);current=next
            }
        }
        let linear=try pass("transfer",current,[],[-1]);arena.release(current);current=linear
        if p.softening.isActive {
            let geometry=try OpticalProcessingGeometry(width:current.width,height:current.height,scale:request.softeningScale.scale)
            let reduced=request.softeningScale != .full
            let base=reduced ? try pass("opticalReduce",current,[],[0,0,0],size:(geometry.width,geometry.height)):current
            let blurred=try blur(base,p.softening.sigma*scale,scaleX:geometry.scaleX,scaleY:geometry.scaleY)
            let next=try pass(reduced ? "softenCombineReduced":"softenCombine",current,[blurred],[Float(p.softening.amount)])
            if reduced {arena.release(base)}
            arena.release(blurred);arena.release(current);current=next
        }
        if p.vignette.enabled,p.vignette.amountEV>0 {
            let v=p.vignette
            let next=try pass("vignette",current,[],[Float(v.amountEV),Float(v.startRadius),Float(v.falloff),Float(v.centerX),Float(v.centerY)])
            arena.release(current);current=next
        }
        if request.previewGlow,p.glow.isActive {
            let g=p.glow,geometry=try OpticalProcessingGeometry(width:current.width,height:current.height,scale:request.glowScale.scale)
            let reduced=request.glowScale != .full
            let hi=reduced ? try pass("opticalReduce",current,[],[1,Float(g.threshold),Float(g.knee)],size:(geometry.width,geometry.height)):try pass("highlights",current,[],[Float(g.threshold),Float(g.knee)])
            let near=try blur(hi,g.nearSigma*scale,scaleX:geometry.scaleX,scaleY:geometry.scaleY)
            let far=try blur(hi,g.farSigma*scale,scaleX:geometry.scaleX,scaleY:geometry.scaleY)
            let next=reduced ? try pass("glowCombineReduced",current,[near,far],[Float(g.amount),Float(g.farWeight),Float(g.threshold),Float(g.knee)]):try pass("glowCombine",current,[hi,near,far],[Float(g.amount),Float(g.farWeight),0])
            arena.release(hi);arena.release(near);arena.release(far);arena.release(current);current=next
        }
        if request.previewGlow,p.halation.isActive {
            let h=p.halation,geometry=try OpticalProcessingGeometry(width:current.width,height:current.height,scale:request.halationScale.scale)
            let reduced=request.halationScale != .full
            let hi=reduced ? try pass("opticalReduce",current,[],[1,Float(h.threshold),Float(h.knee)],size:(geometry.width,geometry.height)):try pass("highlights",current,[],[Float(h.threshold),Float(h.knee)])
            let scattered=try blur(hi,h.sigma*scale,scaleX:geometry.scaleX,scaleY:geometry.scaleY)
            let next=reduced ? try pass("halationCombineReduced",current,[scattered],CameraEffectUniforms.halation(h)+[Float(h.threshold),Float(h.knee)]):try pass("halationCombine",current,[hi,scattered],CameraEffectUniforms.halation(h))
            arena.release(hi);arena.release(scattered);arena.release(current);current=next
        }
        var luma=current,chroma=current
        if p.noise.isActive {
            let key=NoiseKey(width:current.width,height:current.height,seed:temporal.noise.seed(request.seed,frameIndex:request.frameIndex),
                             lumaSigma:p.noise.lumaSigma*scale,chromaSigma:p.noise.chromaSigma*scale)
            if let cached=arena.noise,key==cached.key {
                luma=cached.luma;chroma=cached.chroma
            } else {
                arena.clearNoise()
                let random=try pass("randomField",current,[],[Float(bitPattern:temporal.noise.seed(request.seed,frameIndex:request.frameIndex))])
                luma=try blur(random,key.lumaSigma,noise:true)
                chroma=try blur(random,key.chromaSigma,noise:true)
                if random !== luma && random !== chroma {arena.release(random)}
                arena.noise=NoiseField(key:key,luma:luma,chroma:chroma)
            }
        }
        let result=try pass("finish",current,[luma,chroma],CameraEffectUniforms.noise(p.noise))
        if p.grain.isActive {
            let grained=try pass("filmGrain",result,[],CameraEffectUniforms.grain(p.grain,scale:scale,seed:request.seed,frameIndex:temporal.grain == .fixed ? 0:request.frameIndex,envelope:curves.grain))
            arena.release(result);return grained
        }
        return result
    }

    private func recycle(_ arena:Arena,generation:UInt64) {
        arena.reset()
        poolLock.lock();defer{poolLock.unlock()}
        // One scratch set per usual preview/processing queue, with a small ceiling.
        if generation==cacheGeneration,available.count<2,arena.byteCount+available.reduce(0,{$0+$1.byteCount})<=cacheByteLimit {available.append(arena)}
    }

    private struct NoiseKey:Equatable {
        let width:Int,height:Int
        let seed:UInt32
        let lumaSigma:Double,chromaSigma:Double
    }
    private struct NoiseField {
        let key:NoiseKey
        let luma:MTLTexture,chroma:MTLTexture
    }
    private final class Arena: @unchecked Sendable {
        let device:MTLDevice
        var textures:[MTLTexture]=[]
        var busy=Set<ObjectIdentifier>()
        private var kernels:[UInt64:(PreparedGaussianKernel,MTLBuffer)]=[:]
        var kernelCount:Int {kernels.count}
        var kernelBytes:Int {kernels.values.reduce(0){$0+$1.1.length}}
        var noise:NoiseField?
        var format:MTLPixelFormat = .rgba16Float
        private var configuration:[Int]=[]
        var byteCount:Int {textures.reduce(0){$0+$1.width*$1.height*(format == .rgba32Float ? 16:8)}}
        func configure(width:Int,height:Int,limit:Int?,format:MTLPixelFormat) {
            let key=[width,height,limit ?? 0,Int(format.rawValue)]
            if key != configuration {clearNoise();textures.removeAll();busy.removeAll();configuration=key}
            self.format=format
        }
        init(device:MTLDevice){self.device=device}
        func take(width:Int,height:Int) throws -> MTLTexture {
            try TextureDimensions.validate(width:width,height:height,device:device)
            if let texture=textures.first(where:{$0.width==width && $0.height==height && !busy.contains(ObjectIdentifier($0))}) {
                busy.insert(ObjectIdentifier(texture));return texture
            }
            let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:format,width:width,height:height,mipmapped:false)
            descriptor.storageMode = .shared;descriptor.usage=[.shaderRead,.shaderWrite]
            guard let texture=device.makeTexture(descriptor:descriptor) else {throw LabError.io("相机风格图像处理内存不足")}
            textures.append(texture);busy.insert(ObjectIdentifier(texture));return texture
        }
        func kernel(sigma:Float,noise:Bool) throws -> (PreparedGaussianKernel,MTLBuffer) {
            let key=UInt64(sigma.bitPattern)*2+(noise ? 1:0)
            if let cached=kernels[key] {return cached}
            // Bound retained weights when the user continuously edits a style or dimensions change.
            if kernels.count>=32 {kernels.removeAll(keepingCapacity:true)}
            let value=try PreparedGaussianKernel(sigma:sigma,noise:noise)
            // Large full-resolution radii can exceed setBytes' 4 KiB limit.
            guard let buffer=value.weights.withUnsafeBytes({device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared)}) else {throw LabError.io("无法分配模糊权重")}
            kernels[key]=(value,buffer);return (value,buffer)
        }
        func release(_ texture:MTLTexture){busy.remove(ObjectIdentifier(texture))}
        func clearNoise(){
            if let noise {release(noise.luma);release(noise.chroma)}
            noise=nil
        }
        func reset(){
            busy.removeAll()
            // Cached fields remain reserved while other passes reuse the scratch textures.
            if let noise {busy.insert(ObjectIdentifier(noise.luma));busy.insert(ObjectIdentifier(noise.chroma))}
        }
    }
}

/// Same sample order and normalization as the reference shader; calculated once per scale.
public struct PreparedGaussianKernel {
    public let radius:Int
    public let weights:[Float]
    public let denominator:Float
    public init(sigma:Float,noise:Bool) throws {
        guard sigma.isFinite,sigma>0,sigma<=256 else {throw LabError.invalid("高斯标准差需要为 0–256 范围内的正有限值")}
        radius=Int(ceil(3*sigma))
        var values=[Float]();values.reserveCapacity(2*radius+1)
        var sum:Float=0
        for i in -radius...radius {
            let value=exp(-Float(i*i)/(2*sigma*sigma))
            values.append(value);sum += noise ? value*value:value
        }
        weights=values;denominator=noise ? sqrt(sum):sum
    }
}
