import Foundation
import Metal
import ImagingCore

/// 已验证的设备风格快照，LUT 在准备时解析并上传。
public final class PreparedCameraStyle: @unchecked Sendable {
    public let style: ResolvedStyle
    fileprivate let curves:PreparedResponseCurves
    fileprivate let color: PreparedColorTransform
    fileprivate let lut: MTLTexture?
    fileprivate let lutIsExactIdentity: Bool
    fileprivate let lutBoundaryPolicy: LUTBoundaryPolicy
    fileprivate let lutBlend: PreparedLUTBlend?
    var hasExactIdentityLUT: Bool { lut != nil && lutIsExactIdentity }
    public var preparationStatistics: StylePreparationStatistics {
        let counts = executionPlan.counts
        return .init(colors:counts.colors, grains:counts.grains, halations:counts.halations)
    }
    let executionPlan: PreparedExecutionPlan
    fileprivate let deviceID: UInt64
    fileprivate init(style: ResolvedStyle, color:PreparedColorTransform, lut: MTLTexture?, deviceID: UInt64, boundaryPolicy: LUTBoundaryPolicy, identity: Bool) {
        self.lutBlend = nil
        self.lutIsExactIdentity = identity
        self.lutBoundaryPolicy = boundaryPolicy
        self.executionPlan = PreparedExecutionPlan(parameters: style.parameters, color: color)
        self.curves=PreparedResponseCurves(style.parameters);self.style=style; self.color=color; self.lut=lut; self.deviceID=deviceID
    }
    fileprivate init(base: PreparedCameraStyle, blend: PreparedLUTBlend) {
        style = base.style; curves = base.curves; color = base.color; executionPlan = base.executionPlan
        deviceID = base.deviceID; lut = nil; lutBlend = blend
        lutIsExactIdentity = blend.allIdentity; lutBoundaryPolicy = blend.boundaryPolicy
    }

}

/// 向调用方的命令缓冲区编码 SDR 或扩展 sRGB 效果。提交前须在原缓冲区内消费或复制结果。
/// 缓冲区完成后，临时纹理可能回收再用。
public final class TextureEffectEncoder: @unchecked Sendable {
    private let device: MTLDevice
    let pipelines: [String: MTLComputePipelineState]
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
    /// 空闲缓存统计，在途资源及调用方持有的 LUT 另行管理。
    public var cacheStatistics:RenderCacheStatistics {
        poolLock.lock();defer{poolLock.unlock()}
        return RenderCacheStatistics(kernelCount:available.reduce(0){$0+$1.kernelCount},textureBytes:available.reduce(0){$0+$1.byteCount},kernelBytes:available.reduce(0){$0+$1.kernelBytes})
    }
    private let precision:RenderingPrecision
    private let cacheByteLimit=256*1024*1024
    public var cachedTextureBytes:Int {
        poolLock.lock();defer{poolLock.unlock()};return available.reduce(0){$0+$1.byteCount}
    }
    /// 清除空闲工作区并更新缓存世代，先前在途的工作区完成后直接释放。
    public func releaseCaches() {
        lutLock.lock();preparedLUTs.removeAll();lutLock.unlock()
        poolLock.lock();defer{poolLock.unlock()};available.removeAll();cacheGeneration &+= 1
    }


    public init(device: MTLDevice, precision:RenderingPrecision = .float16) throws {
        self.device=device;self.precision=precision
        let library=try RenderingResources.makeLibrary(device:device)
        var compiled=[String:MTLComputePipelineState]()
        for name in ["weightedLUTMap", "copyPixels", "lutMapExtrapolated","toneResponseExtended","finishExtended","filmGrainExtended","grainReduceExtended","transfer","lutMap","gaussianPrepared","detailCombine","sharpen","vignette","highlights","glowCombine","resizeLinear","randomField","finish"] + CameraEffectUniforms.kernels + ["opticalReduceRegion", "softenCombineReducedRegion", "glowCombineReducedRegion", "halationCombineReducedRegion", "randomFieldRegion", "vignetteRegion", "resizeLinearRegion"] {
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
        let prepared = try prepareLUT(lut)
        return PreparedCameraStyle(style:style,color:try ColorTransform.prepare(style.parameters.color),lut:prepared?.texture,deviceID:device.registryID,boundaryPolicy:lut?.boundaryPolicy ?? .automatic,identity:prepared?.isExactIdentity ?? false)
    }

    public func prepareCorrection(_ correction:DeviceCorrection?,lut:LUTAsset?=nil) throws -> PreparedDeviceCorrection? {
        try PreparedDeviceCorrection.prepare(correction,preparedLUT:prepareLUT(lut),device:device)
    }

    public func encode(_ input: MTLTexture, style: PreparedCameraStyle, correction:PreparedDeviceCorrection? = nil, request:RenderRequest,
                       commandBuffer: MTLCommandBuffer) throws -> MTLTexture {
        try encodeFrame(input,executionPlan:style.executionPlan,parameters:style.style.parameters,color:style.color,curves:style.curves,lut:style.lut,lutBoundaryPolicy:style.lutBoundaryPolicy,lutIdentity:style.lutIsExactIdentity,styleDeviceID:style.deviceID,
                        temporal:style.style.temporalPolicy,correction:correction,request:request,commandBuffer:commandBuffer)
    }
    func encodeRegion(_ input: MTLTexture, style: PreparedCameraStyle, correction: PreparedDeviceCorrection?,
                      request: RenderRequest, geometry: RenderGeometry, workingSet: TileWorkingSet, commandBuffer: MTLCommandBuffer) throws -> MTLTexture {
        try encodeFrame(input, executionPlan: style.executionPlan, parameters: style.style.parameters, color: style.color,
            curves: style.curves, lut: style.lut, lutBoundaryPolicy:style.lutBoundaryPolicy, lutIdentity:style.lutIsExactIdentity, styleDeviceID: style.deviceID, temporal: style.style.temporalPolicy,
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
                               curves:style.fixed.curves,lut:style.fixed.lut,lutBoundaryPolicy:style.fixed.lutBoundaryPolicy,lutIdentity:style.fixed.lutIsExactIdentity,styleDeviceID:style.fixed.deviceID,temporal:values.temporalPolicy,
                               correction:correction,request:request,commandBuffer:commandBuffer)
    }
    /// 复用已上传的 LUT 和执行缓存，每帧仅组装同设备、同边界语义的绑定及权重。
    func blendStyle(base: PreparedCameraStyle, styles: [PreparedCameraStyle], weights: [Double]) throws -> PreparedCameraStyle {
        guard (1...4).contains(styles.count), styles.count == weights.count,
              weights.allSatisfy({ $0.isFinite && $0 > 0 }), abs(weights.reduce(0,+) - 1) <= 1e-9,
              styles.allSatisfy({ $0.deviceID == base.deviceID && $0.lutBoundaryPolicy == styles[0].lutBoundaryPolicy }) else { throw LabError.invalid("Invalid prepared LUT blend") }
        var textures = try styles.map { style -> MTLTexture in
            guard let texture = style.lut else { throw LabError.invalid("Missing resident LUT") }; return texture
        }
        var coefficients = weights.map(Float.init)
        while textures.count < 4 { textures.append(textures[0]); coefficients.append(0) }
        return PreparedCameraStyle(base: base, blend: .init(textures: textures, weights: coefficients,
            boundaryPolicy: styles[0].lutBoundaryPolicy, allIdentity: styles.allSatisfy(\.lutIsExactIdentity)))
    }
    /// 编码前按实际输入范围和整帧几何检查 Float16 中间存储。
    func checkModelSafety(style: PreparedCameraStyle, parameters: StyleParameters, prefix: PreparedDeviceCorrection?, request: RenderRequest, geometry: RenderGeometry? = nil) throws {
        guard precision == .float16 else { return }
        guard let bounds = request.inputValueBounds else { throw LabError.invalid("Prepared input requires trusted bounds") }
        let limit = min(request.maximumLongEdge ?? max(request.input.width, request.input.height), max(request.input.width, request.input.height))
        let ratio = Double(limit) / Double(max(request.input.width, request.input.height))
        let width = max(1, Int(Double(request.input.width) * ratio)), height = max(1, Int(Double(request.input.height) * ratio))
        try PrecisionSafety.validate(bound: max(abs(bounds.lower), abs(bounds.upper)), parameters: parameters,
            color: style.executionPlan.color(for: parameters.color), correction: prefix,
            lut: style.lut == nil && style.lutBlend == nil ? nil : .init(identity: style.lutIsExactIdentity, extrapolates: style.lutBoundaryPolicy.extrapolates(in: request.dynamicRange)),
            precision: .float16, extended: request.dynamicRange == .edr,
            scale: EffectScale.factor(width: geometry?.fullWidth ?? width, height: geometry?.fullHeight ?? height), resizing: (geometry?.fullWidth ?? width) != (geometry?.sourceWidth ?? request.input.width) || (geometry?.fullHeight ?? height) != (geometry?.sourceHeight ?? request.input.height),
            previewGlow: request.previewGlow, preparedGrain: parameters.grain.isActive ? style.executionPlan.grain(for: parameters.grain) : nil)
    }
    func encodeModel(_ input: MTLTexture, style: PreparedCameraStyle, parameters: StyleParameters,
                     prefix: PreparedDeviceCorrection?, request: RenderRequest, workingSet: TileWorkingSet,
                     geometry: RenderGeometry? = nil, commandBuffer: MTLCommandBuffer) throws -> MTLTexture {
        try encodeFrame(input, executionPlan: style.executionPlan, parameters: parameters,
            color: style.executionPlan.color(for: parameters.color), curves: style.executionPlan.curves(for: parameters),
            lut: style.lut, lutBoundaryPolicy: style.lutBoundaryPolicy, lutIdentity: style.lutIsExactIdentity,
            styleDeviceID: style.deviceID, temporal: style.style.temporalPolicy, correction: prefix,
            request: request, geometry: geometry, workingSet: workingSet, commandBuffer: commandBuffer, precisionChecked: true, lutBlend: style.lutBlend)
    }
    private func encodeFrame(_ input:MTLTexture,executionPlan:PreparedExecutionPlan,parameters p:StyleParameters,color:PreparedColorTransform,curves:PreparedResponseCurves,lut:MTLTexture?,lutBoundaryPolicy:LUTBoundaryPolicy,lutIdentity:Bool,
                             styleDeviceID:UInt64,temporal:TemporalPolicy,correction:PreparedDeviceCorrection?,
                             request:RenderRequest,geometry:RenderGeometry? = nil,workingSet:TileWorkingSet? = nil,commandBuffer:MTLCommandBuffer,precisionChecked:Bool = false,lutBlend:PreparedLUTBlend? = nil) throws -> MTLTexture {
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
        let hasEffects=correction != nil || p.color.isActive || lut != nil || lutBlend != nil || p.tone.isActive || p.detail.isActive || p.softening.isActive || p.vignette.isActive || (request.previewGlow && (p.glow.isActive || p.halation.isActive)) || p.noise.isActive || p.grain.isActive

        // 先检查组合颜色增益是否适合 Float32 算术，再按所选半精度校验各阶段存储。
        let colorBound=color.maximumGain
        let correctionBound=correction?.color.maximumGain ?? 1
        let combinedBound=max(correctionBound,colorBound*(correction?.lutTexture == nil ? correctionBound:1))
        guard combinedBound.isFinite,combinedBound < Double(Float.greatestFiniteMagnitude)/1024 else {throw LabError.invalid("组合颜色变换超出浮点安全范围")}
        let format: MTLPixelFormat = precision == .float32 ? .rgba32Float : .rgba16Float
        if precision == .float16 && !precisionChecked {
            guard let bounds = request.inputValueBounds ?? (extended ? nil : NumericBounds(lower: 0, upper: 1)) else {
                throw LabError.unsupported("Float16 requires trusted EDR input bounds; select Float32 explicitly")
            }
            try PrecisionSafety.validate(bound: max(abs(bounds.lower), abs(bounds.upper)), parameters: p, color: color,
                correction: correction, lut: lut == nil ? nil : .init(identity: lutIdentity, extrapolates: lutBoundaryPolicy.extrapolates(in: request.dynamicRange)),
                precision: .float16, extended: extended, scale: EffectScale.factor(width: frameGeometry.fullWidth, height: frameGeometry.fullHeight), resizing: needsResize, previewGlow: request.previewGlow, preparedGrain: p.grain.isActive ? executionPlan.grain(for: p.grain) : nil)
        }
        if !hasEffects && !needsResize && input.pixelFormat == format { return input }
        // 锁只保护空闲池和世代，取出的工作区在当前命令内独占。
        poolLock.lock()
        let pooled = geometry == nil && workingSet == nil
        let arena = pooled ? (available.popLast() ?? Arena(device:device)) : Arena(device:device, workingSet:workingSet)
        let generation=cacheGeneration
        poolLock.unlock()
        arena.configure(width:input.width,height:input.height,limit:maximumLongEdge,format:format)
        // Resources remain reserved until completion even if encoding throws after its first pass.
        commandBuffer.addCompletedHandler { [weak self,arena] command in
            if command.status == .error {arena.clearNoise()}
            if pooled { self?.recycle(arena,generation:generation) }
        }
        if !p.noise.isActive {arena.clearNoise()}
        let backend=RealtimeEffectBackend(arena:arena,pipelines:pipelines,commandBuffer:commandBuffer,geometry:geometry,frameGeometry:frameGeometry)
        if !hasEffects && !needsResize { return try backend.pass("copyPixels", input) }
        let frame=EffectFrame(executionPlan:executionPlan,parameters:p,color:color,curves:curves,lut:lut,lutBoundaryPolicy:lutBoundaryPolicy,correction:correction,temporal:temporal,request:request,geometry:frameGeometry,lutBlend:lutBlend)
        let pipeline=EffectPipeline(backend:backend,frame:frame)
        return try pipeline.encodeSuffix(pipeline.encodePrefix(pipeline.prepareInput(input)))
    }

    private func recycle(_ arena:Arena,generation:UInt64) {
        arena.reset()
        poolLock.lock();defer{poolLock.unlock()}
        // One scratch set per usual preview/processing queue, with a small ceiling.
        if generation==cacheGeneration,available.count<2,arena.byteCount+available.reduce(0,{$0+$1.byteCount})<=cacheByteLimit {available.append(arena)}
    }


}

/// 与参考着色器采样顺序及归一化一致的高斯权重，可按尺度复用。
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
