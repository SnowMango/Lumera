import Foundation
import Metal
import ImagingCore

/// Immutable, validated snapshot. LUT upload and parsing happen once, outside the frame loop.
public final class PreparedCameraStyle: @unchecked Sendable {
    public let style: ResolvedStyle
    fileprivate let curves:PreparedResponseCurves
    fileprivate let color: PreparedColorTransform
    fileprivate let lut: MTLTexture?
    fileprivate let lutBoundaryPolicy: LUTBoundaryPolicy
    public var preparationStatistics: StylePreparationStatistics {
        let counts = executionPlan.counts
        return .init(colors:counts.colors, grains:counts.grains, halations:counts.halations)
    }
    let executionPlan: PreparedExecutionPlan
    fileprivate let deviceID: UInt64
    fileprivate init(style: ResolvedStyle, color:PreparedColorTransform, lut: MTLTexture?, deviceID: UInt64, boundaryPolicy: LUTBoundaryPolicy) {
        self.lutBoundaryPolicy = boundaryPolicy
        self.executionPlan = PreparedExecutionPlan(parameters: style.parameters, color: color)
        self.curves=PreparedResponseCurves(style.parameters);self.style=style; self.color=color; self.lut=lut; self.deviceID=deviceID
    }
}

/// Encodes the SDR or extended-sRGB pipeline into the caller's command buffer without submitting or waiting.
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
        for name in ["lutMapExtrapolated","toneResponseExtended","finishExtended","filmGrainExtended","grainReduceExtended","transfer","lutMap","gaussianPrepared","detailCombine","sharpen","vignette","highlights","glowCombine","resizeLinear","randomField","finish"] + CameraEffectUniforms.kernels + ["opticalReduceRegion", "softenCombineReducedRegion", "glowCombineReducedRegion", "halationCombineReducedRegion", "randomFieldRegion", "vignetteRegion", "resizeLinearRegion"] {
            guard let function=library.makeFunction(name:name) else {throw LabError.io("缺少 风格处理函数："+name)}
            compiled[name]=try device.makeComputePipelineState(function:function)
        }
        pipelines=compiled
    }

    private func prepareLUT(_ asset:LUTAsset?) throws -> PreparedLUT? {
        guard let asset else{return nil};try asset.validate()
        lutLock.lock();defer{lutLock.unlock()}
        if let index=preparedLUTs.firstIndex(where:{$0.digest==asset.sha256 && $0.boundaryPolicy==asset.boundaryPolicy}) {
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
        return PreparedCameraStyle(style:style,color:try ColorTransform.prepare(style.parameters.color),lut:try prepareLUT(lut)?.texture,deviceID:device.registryID,boundaryPolicy:lut?.boundaryPolicy ?? .automatic)
    }

    public func prepareCorrection(_ correction:DeviceCorrection?,lut:LUTAsset?=nil) throws -> PreparedDeviceCorrection? {
        try PreparedDeviceCorrection.prepare(correction,preparedLUT:prepareLUT(lut),device:device)
    }

    public func encode(_ input: MTLTexture, style: PreparedCameraStyle, correction:PreparedDeviceCorrection? = nil, request:RenderRequest,
                       commandBuffer: MTLCommandBuffer) throws -> MTLTexture {
        try encodeFrame(input,executionPlan:style.executionPlan,parameters:style.style.parameters,color:style.color,curves:style.curves,lut:style.lut,lutBoundaryPolicy:style.lutBoundaryPolicy,styleDeviceID:style.deviceID,
                        temporal:style.style.temporalPolicy,correction:correction,request:request,commandBuffer:commandBuffer)
    }
    func encodeRegion(_ input: MTLTexture, style: PreparedCameraStyle, correction: PreparedDeviceCorrection?,
                      request: RenderRequest, geometry: RenderGeometry, workingSet: TileWorkingSet, commandBuffer: MTLCommandBuffer) throws -> MTLTexture {
        try encodeFrame(input, executionPlan: style.executionPlan, parameters: style.style.parameters, color: style.color,
            curves: style.curves, lut: style.lut, lutBoundaryPolicy:style.lutBoundaryPolicy, styleDeviceID: style.deviceID, temporal: style.style.temporalPolicy,
            correction: correction, request: request, geometry: geometry, workingSet: workingSet, commandBuffer: commandBuffer)
    }
    public func prepare(_ definition:CompiledStyleDefinition,lut:LUTAsset?=nil) throws -> PreparedStyleDefinition {
        let fixed=try prepare(ResolvedStyle(parameters:definition.parameters,profileDigest:definition.identity,temporalPolicy:definition.temporalPolicy),lut:lut)
        return PreparedStyleDefinition(definition:definition,fixed:fixed)
    }
    public func encode(_ input:MTLTexture,style:PreparedStyleDefinition,parameters:FrameStyleParameters,
                       correction:PreparedDeviceCorrection?=nil,request:RenderRequest,commandBuffer:MTLCommandBuffer) throws -> MTLTexture {
        let values=parameters.evaluated
        guard values.definitionIdentity==style.definition.identity else {throw LabError.invalid("帧参数不属于此已准备风格定义")}
        return try encodeFrame(input,executionPlan:style.fixed.executionPlan,parameters:values.parameters,color:style.fixed.executionPlan.color(for: values.parameters.color),
                               curves:style.fixed.curves,lut:style.fixed.lut,lutBoundaryPolicy:style.fixed.lutBoundaryPolicy,styleDeviceID:style.fixed.deviceID,temporal:values.temporalPolicy,
                               correction:correction,request:request,commandBuffer:commandBuffer)
    }
    private func encodeFrame(_ input:MTLTexture,executionPlan:PreparedExecutionPlan,parameters p:StyleParameters,color:PreparedColorTransform,curves:PreparedResponseCurves,lut:MTLTexture?,lutBoundaryPolicy:LUTBoundaryPolicy,
                             styleDeviceID:UInt64,temporal:TemporalPolicy,correction:PreparedDeviceCorrection?,
                             request:RenderRequest,geometry:RenderGeometry? = nil,workingSet:TileWorkingSet? = nil,commandBuffer:MTLCommandBuffer) throws -> MTLTexture {
        try request.validate()
        guard input.device.registryID==device.registryID, styleDeviceID==device.registryID,
              correction == nil || correction!.deviceID==device.registryID,
              commandBuffer.device.registryID==device.registryID, commandBuffer.status == .notEnqueued,
              commandBuffer.retainedReferences,
              input.textureType == .type2D, input.width==request.input.width,input.height==request.input.height,
              [.rgba8Unorm,.bgra8Unorm,.rgba16Float,.rgba32Float].contains(input.pixelFormat) else {
            throw LabError.invalid("纹理尺寸、格式或设备与请求不符；请传入保留资源引用且尚未提交的 command buffer")
        }
        let extended = request.dynamicRange == .edr
        if extended && ![MTLPixelFormat.rgba16Float, .rgba32Float].contains(input.pixelFormat) {
            throw LabError.invalid("EDR 纹理需要 RGBA16Float 或 RGBA32Float；数值使用扩展编码 sRGB")
        }
        let limit = min(request.maximumLongEdge ?? max(input.width,input.height), max(input.width,input.height))
        let ratio = Double(limit) / Double(max(input.width,input.height))
        let width = max(1, Int(Double(input.width) * ratio)), height = max(1, Int(Double(input.height) * ratio))
        let frameGeometry = geometry ?? RenderGeometry(fullWidth: width, fullHeight: height,
            area: CGRect(x:0,y:0,width:width,height:height), sourceWidth: input.width, sourceHeight: input.height,
            sourceArea: CGRect(x:0,y:0,width:input.width,height:input.height))
        let needsResize = frameGeometry.sourceWidth != frameGeometry.fullWidth || frameGeometry.sourceHeight != frameGeometry.fullHeight
        let maximumLongEdge=request.maximumLongEdge
        let hasEffects=correction != nil || p.color.isActive || lut != nil || p.tone.isActive || p.detail.isActive || p.softening.isActive || p.vignette.isActive || (request.previewGlow && (p.glow.isActive || p.halation.isActive)) || p.noise.isActive || p.grain.isActive
        if !hasEffects && !needsResize { return input }
        // An extreme but valid white-point transform can exceed half-float optical intermediates.
        // Conservative row-sum bound leaves headroom for detail and diffusion; use Float32 then.
        let colorBound=color.maximumGain
        let correctionBound=correction?.color.maximumGain ?? 1
        let combinedBound=max(correctionBound,colorBound*(correction?.lutTexture == nil ? correctionBound:1))
        guard combinedBound.isFinite,combinedBound < Double(Float.greatestFiniteMagnitude)/1024 else {throw LabError.invalid("组合颜色变换超出浮点安全范围")}
        // Extrapolation can exceed half-float even from bounded SDR source pixels after
        // color correction. A later transform may bring the result back into SDR.
        let extrapolating = (lut != nil && lutBoundaryPolicy.extrapolates(in: request.dynamicRange)) ||
            (correction?.lutTexture != nil && correction!.lutBoundaryPolicy.extrapolates(in: request.dynamicRange))
        let format:MTLPixelFormat=(precision == .float32 || extended || extrapolating || combinedBound>256) ? .rgba32Float:.rgba16Float
        poolLock.lock()
        let arena = geometry == nil ? (available.popLast() ?? Arena(device:device)) : Arena(device:device, workingSet:workingSet)
        let generation=cacheGeneration
        poolLock.unlock()
        arena.configure(width:input.width,height:input.height,limit:maximumLongEdge,format:format)
        // Resources remain reserved until completion even if encoding throws after its first pass.
        commandBuffer.addCompletedHandler { [weak self,arena] command in
            if command.status == .error {arena.clearNoise()}
            if geometry == nil { self?.recycle(arena,generation:generation) }
        }
        if !p.noise.isActive {arena.clearNoise()}
        var grid: OpticalGrid?
        func opticalGeometry(_ resolution: EffectResolution) -> OpticalGrid {
            let value = frameGeometry.opticalGrid(resolution)
            grid = value
            return value
        }
        func pass(_ name:String,_ source:MTLTexture,_ extras:[MTLTexture]=[],_ parameters:[Float]=[0],size:(Int,Int)?=nil,weights:MTLBuffer?=nil) throws -> MTLTexture {
            let result=try arena.take(width:size?.0 ?? source.width,height:size?.1 ?? source.height)
            let regionOptical = geometry != nil && (name == "opticalReduce" || name.hasSuffix("CombineReduced"))
            let regional = regionOptical || (geometry != nil && ["vignette", "randomField", "resizeLinear"].contains(name))
            let functionName = regional ? name + "Region" : name
            guard let state=pipelines[functionName],let encoder=commandBuffer.makeComputeCommandEncoder() else {throw LabError.io("无法创建 风格渲染 GPU 任务")}
            encoder.setComputePipelineState(state)
            encoder.setTexture(source,index:0);encoder.setTexture(result,index:1)
            for (i,texture) in extras.enumerated(){encoder.setTexture(texture,index:i+2)}
            parameters.withUnsafeBytes{encoder.setBytes($0.baseAddress!,length:$0.count,index:0)}
            if regional {
                let g = frameGeometry
                var values = [Float(g.originX), Float(g.originY), Float(g.fullWidth), Float(g.fullHeight)]
                if regionOptical, let grid {
                    values += [Float(grid.scaleX), Float(grid.scaleY), Float(grid.x), Float(grid.y),
                               Float((Double(g.fullWidth)*grid.scaleX).rounded()), Float((Double(g.fullHeight)*grid.scaleY).rounded())]
                } else if name == "resizeLinear" {
                    values += [Float(g.sourceWidth), Float(g.sourceHeight), Float(g.sourceX), Float(g.sourceY)]
                }
                values.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length:$0.count, index:2) }
            }
            if let weights {encoder.setBuffer(weights,offset:0,index:1)}
            encoder.dispatchThreads(MTLSize(width:result.width,height:result.height,depth:1),threadsPerThreadgroup:MTLSize(width:16,height:16,depth:1))
            encoder.endEncoding();return result
        }
        func blur(_ source:MTLTexture,_ sigma:Double,noise:Bool=false,scaleX:Double=1,scaleY:Double=1,integrated:Bool=false) throws -> MTLTexture {
            func axis(_ input:MTLTexture,_ radius:Double,_ direction:Float) throws -> MTLTexture {
                if !integrated && radius<0.08{return input}
                let (kernel,weights)=try arena.kernel(sigma:Float(radius),noise:noise,integrated:integrated)
                return try pass("gaussianPrepared",input,[],[Float(kernel.radius),direction,kernel.denominator,noise ? 1:0],weights:weights)
            }
            let x=try axis(source,sigma*scaleX,0),y=try axis(x,sigma*scaleY,1)
            if x !== source && x !== y {arena.release(x)}
            return y
        }
        var current=input
        if let correction {
            if correction.colorIsActive {current=try pass("colorResponse",current,[],correction.color.uniforms)}
            if let lut=correction.lutTexture {let next=try pass(correction.lutBoundaryPolicy.extrapolates(in: request.dynamicRange) ? "lutMapExtrapolated" : "lutMap",current,[lut]);arena.release(current);current=next}
        }
        if needsResize {
            let linear=try pass("transfer",current,[],[-1]);arena.release(current)
            let scaled=try pass("resizeLinear",linear,size:(frameGeometry.width,frameGeometry.height));arena.release(linear)
            current=try pass("transfer",scaled,[],[1]);arena.release(scaled)
        }
        let scale=EffectScale.factor(width:frameGeometry.fullWidth,height:frameGeometry.fullHeight)
        if p.color.isActive {let next=try pass("colorResponse",current,[],color.uniforms);arena.release(current);current=next}
        if let lut {let next=try pass(lutBoundaryPolicy.extrapolates(in: request.dynamicRange) ? "lutMapExtrapolated" : "lutMap",current,[lut]);arena.release(current);current=next}
        if p.tone.isActive {let next=try pass(extended ? "toneResponseExtended" : "toneResponse",current,[],curves.tone);arena.release(current);current=next}
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
            let geometry=opticalGeometry(request.softeningScale)
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
            let g=p.glow,geometry=opticalGeometry(request.glowScale)
            let reduced=request.glowScale != .full
            let hi=reduced ? try pass("opticalReduce",current,[],[1,Float(g.threshold),Float(g.knee)],size:(geometry.width,geometry.height)):try pass("highlights",current,[],[Float(g.threshold),Float(g.knee)])
            let near=try blur(hi,g.nearSigma*scale,scaleX:geometry.scaleX,scaleY:geometry.scaleY)
            let far=try blur(hi,g.farSigma*scale,scaleX:geometry.scaleX,scaleY:geometry.scaleY)
            let next=reduced ? try pass("glowCombineReduced",current,[near,far],[Float(g.amount),Float(g.farWeight),Float(g.threshold),Float(g.knee)]):try pass("glowCombine",current,[hi,near,far],[Float(g.amount),Float(g.farWeight),0])
            arena.release(hi);arena.release(near);arena.release(far);arena.release(current);current=next
        }
        if request.previewGlow,p.halation.isActive {
            let h=p.halation,geometry=opticalGeometry(request.halationScale)
            let reduced=request.halationScale != .full
            let hi=reduced ? try pass("opticalReduce",current,[],[1,Float(h.threshold),Float(h.knee)],size:(geometry.width,geometry.height)):try pass("highlights",current,[],[Float(h.threshold),Float(h.knee)])
            let scattered=try executionPlan.halation(for:h).sigmas.map { try blur(hi,$0*scale,scaleX:geometry.scaleX,scaleY:geometry.scaleY,integrated:true) }
            let next=reduced ? try pass("halationCombineReduced",current,scattered,CameraEffectUniforms.halation(h)+[Float(h.threshold),Float(h.knee)]):try pass("halationCombine",current,[hi]+scattered,CameraEffectUniforms.halation(h))
            arena.release(hi);scattered.forEach(arena.release);arena.release(current);current=next
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
        let result=try pass(extended ? "finishExtended" : "finish",current,[luma,chroma],CameraEffectUniforms.noise(p.noise,envelope:curves.noise))
        if p.grain.isActive {
            let prepared = executionPlan.grain(for:p.grain)
            let uniforms = CameraEffectUniforms.grain(p.grain,scale:scale,seed:request.seed,
                frameIndex:temporal.grain == .fixed ? 0:request.frameIndex,envelope:curves.grain,
                originX:frameGeometry.originX,originY:frameGeometry.originY,prepared:prepared)
            let factor = prepared.subdivision(scale:scale)
            let grained: MTLTexture
            if factor > 1 {
                let subpixels = try pass("grainSubpixels",result,[],uniforms,size:(result.width*factor,result.height*factor))
                grained = try pass(extended ? "grainReduceExtended" : "grainReduce",result,[subpixels],uniforms)
                arena.release(subpixels)
            } else {
                grained = try pass(extended ? "filmGrainExtended" : "filmGrain",result,[],uniforms)
            }
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
        let workingSet: TileWorkingSet?
        init(device:MTLDevice, workingSet: TileWorkingSet? = nil){self.device=device; self.workingSet = workingSet}
        func take(width:Int,height:Int) throws -> MTLTexture {
            try TextureDimensions.validate(width:width,height:height,device:device)
            if let texture=textures.first(where:{$0.width==width && $0.height==height && !busy.contains(ObjectIdentifier($0))}) {
                busy.insert(ObjectIdentifier(texture));return texture
            }
            let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:format,width:width,height:height,mipmapped:false)
            descriptor.storageMode = .shared;descriptor.usage=[.shaderRead,.shaderWrite]
            try workingSet?.reserve(texture:descriptor,on:device)
            guard let texture=device.makeTexture(descriptor:descriptor) else {throw LabError.io("相机风格图像处理内存不足")}
            textures.append(texture);busy.insert(ObjectIdentifier(texture));return texture
        }
        func kernel(sigma:Float,noise:Bool,integrated:Bool) throws -> (PreparedGaussianKernel,MTLBuffer) {
            let key=UInt64(sigma.bitPattern)*4+(integrated ? 2 : (noise ? 1 : 0))
            if let cached=kernels[key] {return cached}
            // Bound retained weights when the user continuously edits a style or dimensions change.
            if kernels.count>=32 {kernels.removeAll(keepingCapacity:true)}
            let value=try PreparedGaussianKernel(sigma:sigma,noise:noise,integrated:integrated)
            // Large full-resolution radii can exceed setBytes' 4 KiB limit.
            try workingSet?.reserve(bufferLength:value.weights.count * MemoryLayout<Float>.stride,on:device)
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
        try self.init(sigma:sigma,noise:noise,integrated:false)
    }

    package init(sigma:Float,noise:Bool,integrated:Bool) throws {
        // Bound kernel storage, rather than imposing a scale limit tied to one image size.
        let support = ceil(Double(sigma) * (integrated ? 4 : 3))
        let maximumRadius = ((16 * 1024 * 1024 / MemoryLayout<Float>.stride) - 1) / 2
        guard sigma.isFinite, sigma > 0, support <= Double(maximumRadius) else {
            throw LabError.invalid("高斯尺度无效或权重超出 16 MiB")
        }
        radius = Int(support)
        var values=[Float]();values.reserveCapacity(2*radius+1)
        var sum:Float=0
        for i in -radius...radius {
            let value:Float
            if integrated {
                let k = sqrt(2.0) * Double(sigma)
                let index = Double(i)
                value = Float((erf((index+0.5)/k) - erf((index-0.5)/k)) / 2)
            } else {
                value = exp(-Float(i*i)/(2*sigma*sigma))
            }
            values.append(value);sum += noise ? value*value:value
        }
        weights=values;denominator=noise ? sqrt(sum):sum
    }
}
