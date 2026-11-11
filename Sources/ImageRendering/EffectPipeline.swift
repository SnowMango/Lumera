import Foundation
import Metal
import ImagingCore

/// 单帧的固定四个 LUT 绑定和权重，空闲槽复用首张纹理，权重为零。
struct PreparedLUTBlend {
    let luts: [PreparedLUT]
    var textures: [MTLTexture] { luts.map(\.texture) }
    let weights: [Float]
    let boundaryPolicy: LUTBoundaryPolicy
}

/// 实时和参考后端共用的已校验帧参数、资源和几何信息。
struct EffectFrame {
    let executionPlan: PreparedExecutionPlan
    let parameters: StyleParameters
    let color: PreparedColorTransform
    let curves: PreparedResponseCurves
    let lut: MTLTexture?
    let lutBoundaryPolicy: LUTBoundaryPolicy
    let correction: PreparedDeviceCorrection?
    let temporal: TemporalPolicy
    let request: RenderRequest
    let geometry: RenderGeometry
    var lutBlend: PreparedLUTBlend? = nil
}

/// 集中定义效果顺序，后端负责纹理、编码和提交策略。
struct EffectPipeline<Backend: EffectPipelineBackend> {
    let backend: Backend
    let frame: EffectFrame
    private var p: StyleParameters { frame.parameters }
    private var executionPlan: PreparedExecutionPlan { frame.executionPlan }
    private var color: PreparedColorTransform { frame.color }
    private var curves: PreparedResponseCurves { frame.curves }
    private var lut: MTLTexture? { frame.lut }
    private var lutBoundaryPolicy: LUTBoundaryPolicy { frame.lutBoundaryPolicy }
    private var correction: PreparedDeviceCorrection? { frame.correction }
    private var temporal: TemporalPolicy { frame.temporal }
    private var request: RenderRequest { frame.request }
    private var frameGeometry: RenderGeometry { frame.geometry }
    private var extended: Bool { request.dynamicRange == .edr }
    private var needsResize: Bool { frameGeometry.sourceWidth != frameGeometry.fullWidth || frameGeometry.sourceHeight != frameGeometry.fullHeight }
    private var scale: Double { EffectScale.factor(width:frameGeometry.fullWidth,height:frameGeometry.fullHeight) }
    private func pass(_ name:String,_ source:Backend.Surface,_ extras:[Backend.Surface]=[],_ parameters:[Float]=[0],size:(Int,Int)?=nil,weights:MTLBuffer?=nil,lut:MTLTexture?=nil) throws -> Backend.Surface {
        try backend.pass(name,source,extras,parameters,size:size,weights:weights,lut:lut,lutTextures:[])
    }
    private func blur(_ source:Backend.Surface,_ sigma:Double,noise:Bool=false,scaleX:Double=1,scaleY:Double=1,integrated:Bool=false) throws -> Backend.Surface {
        try backend.blur(source,sigma,noise:noise,scaleX:scaleX,scaleY:scaleY,integrated:integrated)
    }
    private func opticalGeometry(_ resolution:EffectResolution) -> OpticalGrid {
        backend.opticalGeometry(resolution,frame:frameGeometry)
    }
    /// 先应用调用路径提供的前置变换，再在线性光中缩放并恢复编码值。
    func prepareInput(_ input:Backend.Surface) throws -> Backend.Surface {
        var current=input
        if let correction {
            if correction.colorIsActive {current=try pass("colorResponse",current,[],correction.color.uniforms)}
            if let lut=correction.lutTexture {let next=try pass(correction.lutBoundaryPolicy.extrapolates(in: request.dynamicRange) ? "lutMapExtrapolated" : "lutMap",current,lut:lut);backend.release(current);current=next}
        }
        if correction != nil { backend.didPrepareCorrection() }
        if needsResize {
            let linear=try pass("transfer",current,[],[-1]);backend.release(current)
            let scaled=try pass("resizeLinear",linear,size:(frameGeometry.width,frameGeometry.height));backend.release(linear)
            current=try pass("transfer",scaled,[],[1]);backend.release(scaled)
        }
        return current
    }
    /// 编码域的色彩、LUT、色调和细节处理之后，在线性光中计算光学效果。
    func encodePrefix(_ input:Backend.Surface) throws -> Backend.Surface {
        var current=input
        if p.color.isActive {let next=try pass("colorResponse",current,[],color.uniforms);backend.release(current);current=next}
        if let blend = frame.lutBlend {
            let next = try backend.pass("weightedLUTMap", current, [], blend.weights + [blend.boundaryPolicy.extrapolates(in: request.dynamicRange) ? 1 : 0], size: nil, weights: nil, lut: nil, lutTextures: blend.textures)
            backend.release(current); current = next
        } else if let lut {let next=try pass(lutBoundaryPolicy.extrapolates(in: request.dynamicRange) ? "lutMapExtrapolated" : "lutMap",current,lut:lut);backend.release(current);current=next}
        if p.tone.isActive {let next=try pass(extended ? "toneResponseExtended" : "toneResponse",current,[],curves.tone);backend.release(current);current=next}
        if p.detail.isActive {
            let fine=try blur(current,p.detail.fineSigma*scale),mid=try blur(current,p.detail.midSigma*scale)
            let next=try pass("detailCombine",current,[fine,mid],[Float(p.detail.fineGain),Float(p.detail.midGain)])
            backend.release(fine);backend.release(mid);backend.release(current);current=next
            if p.detail.sharpenAmount>0 {
                let blurred=try blur(current,p.detail.sharpenSigma*scale)
                let next=try pass("sharpen",current,[blurred],[Float(p.detail.sharpenAmount),Float(p.detail.threshold),Float(p.detail.maxAdjustment)])
                backend.release(blurred);backend.release(current);current=next
            }
        }
        do {
            let linear=try pass("transfer",current,[],[-1]);backend.release(current);current=linear
        }
        if p.softening.isActive {
            let geometry=opticalGeometry(request.softeningScale)
            let reduced=request.softeningScale != .full
            let base=reduced ? try pass("opticalReduce",current,[],[0,0,0],size:(geometry.width,geometry.height)):current
            let blurred=try blur(base,p.softening.sigma*scale,scaleX:geometry.scaleX,scaleY:geometry.scaleY)
            let next=try pass(reduced ? "softenCombineReduced":"softenCombine",current,[blurred],[Float(p.softening.amount)])
            if reduced {backend.release(base)}
            backend.release(blurred);backend.release(current);current=next
        }
        if p.vignette.enabled,p.vignette.amountEV>0 {
            let v=p.vignette
            let next=try pass("vignette",current,[],[Float(v.amountEV),Float(v.startRadius),Float(v.falloff),Float(v.centerX),Float(v.centerY)])
            backend.release(current);current=next
        }
        if request.previewGlow,p.glow.isActive {
            let g=p.glow,geometry=opticalGeometry(request.glowScale)
            let reduced=request.glowScale != .full
            let hi=reduced ? try pass("opticalReduce",current,[],[1,Float(g.threshold),Float(g.knee)],size:(geometry.width,geometry.height)):try pass("highlights",current,[],[Float(g.threshold),Float(g.knee)])
            let near=try blur(hi,g.nearSigma*scale,scaleX:geometry.scaleX,scaleY:geometry.scaleY)
            let far=try blur(hi,g.farSigma*scale,scaleX:geometry.scaleX,scaleY:geometry.scaleY)
            let next=reduced ? try pass("glowCombineReduced",current,[near,far],[Float(g.amount),Float(g.farWeight),Float(g.threshold),Float(g.knee)]):try pass("glowCombine",current,[hi,near,far],[Float(g.amount),Float(g.farWeight),0])
            backend.release(hi);backend.release(near);backend.release(far);backend.release(current);current=next
        }
        if request.previewGlow,p.halation.isActive {
            let h=p.halation,geometry=opticalGeometry(request.halationScale)
            let reduced=request.halationScale != .full
            let hi=reduced ? try pass("opticalReduce",current,[],[1,Float(h.threshold),Float(h.knee)],size:(geometry.width,geometry.height)):try pass("highlights",current,[],[Float(h.threshold),Float(h.knee)])
            let scattered=try executionPlan.halation(for:h).sigmas.map { try blur(hi,$0*scale,scaleX:geometry.scaleX,scaleY:geometry.scaleY,integrated:true) }
            let next=reduced ? try pass("halationCombineReduced",current,scattered,EffectUniforms.halation(h)+[Float(h.threshold),Float(h.knee)]):try pass("halationCombine",current,[hi]+scattered,EffectUniforms.halation(h))
            backend.release(hi);scattered.forEach(backend.release);backend.release(current);current=next
        }
        return current
    }
    /// 应用时序噪声及颗粒，并按输出范围完成像素编码。
    func encodeSuffix(_ input:Backend.Surface) throws -> Backend.Surface {
        let current=input
        var luma=current,chroma=current
        if p.noise.isActive {
            let key=NoiseKey(width:backend.texture(current).width,height:backend.texture(current).height,seed:temporal.noise.seed(request.seed,frameIndex:request.frameIndex),
                             lumaSigma:p.noise.lumaSigma*scale,chromaSigma:p.noise.chromaSigma*scale)
            if let cached=backend.noise,key==cached.key {
                luma=cached.luma;chroma=cached.chroma
            } else {
                backend.clearNoise()
                let random=try pass("randomField",current,[],[Float(bitPattern:temporal.noise.seed(request.seed,frameIndex:request.frameIndex))])
                luma=try blur(random,key.lumaSigma,noise:true)
                chroma=try blur(random,key.chromaSigma,noise:true)
                if random !== luma && random !== chroma {backend.release(random)}
                backend.noise=EffectNoiseField(key:key,luma:luma,chroma:chroma)
            }
        }
        let result=try pass(extended ? "finishExtended" : "finish",current,[luma,chroma],EffectUniforms.noise(p.noise,envelope:curves.noise))
        if p.grain.isActive {
            let prepared = executionPlan.grain(for:p.grain)
            let uniforms = EffectUniforms.grain(p.grain,scale:scale,seed:request.seed,
                frameIndex:temporal.grain == .fixed ? 0:request.frameIndex,envelope:curves.grain,
                originX:frameGeometry.originX,originY:frameGeometry.originY,prepared:prepared)
            let factor = prepared.subdivision(scale:scale)
            let grained: Backend.Surface
            if factor > 1 {
                let subpixels = try pass("grainSubpixels",result,[],uniforms,size:(backend.texture(result).width*factor,backend.texture(result).height*factor))
                grained = try pass(extended ? "grainReduceExtended" : "grainReduce",result,[subpixels],uniforms)
                backend.release(subpixels)
            } else {
                grained = try pass(extended ? "filmGrainExtended" : "filmGrain",result,[],uniforms)
            }
            backend.release(result);return grained
        }
        return result
    }
}
