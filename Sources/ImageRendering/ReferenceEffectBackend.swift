import Foundation
import Metal
import ImagingCore

/// 使用串行参考会话的 Float32 纹理租约，记录前置校正的工作量。
final class ReferenceEffectBackend:EffectPipelineBackend {
    let session:ReferenceRenderSession
    let correctionStart:Double
    let correctionDispatchStart:Int
    init(session:ReferenceRenderSession){self.session=session;correctionStart=ProcessInfo.processInfo.systemUptime;correctionDispatchStart=session.lastWork.dispatches}
    func didPrepareCorrection(){
        session.lastWork.correctionDispatches=session.lastWork.dispatches-correctionDispatchStart
        session.lastWork.correctionSeconds += ProcessInfo.processInfo.systemUptime-correctionStart
    }
    var noise:EffectNoiseField<TextureLease>?
    func texture(_ surface:TextureLease)->MTLTexture{surface.texture}
    func release(_ surface:TextureLease) {} // ARC leases keep storage live through its final reader.
    func clearNoise(){noise=nil}
    func opticalGeometry(_ resolution:EffectResolution,frame:RenderGeometry)->OpticalGrid{frame.opticalGrid(resolution)}
    func pass(_ name:String,_ source:TextureLease,_ extras:[TextureLease],_ parameters:[Float],size:(Int,Int)?,weights:MTLBuffer?,lut:MTLTexture?,lutTextures:[MTLTexture])throws->TextureLease {
        try session.pass(name,source,extras,parameters,size:size,lut:lut,weights:weights,lutTextures:lutTextures)
    }
    func blur(_ source:TextureLease,_ sigma:Double,noise:Bool,scaleX:Double,scaleY:Double,integrated:Bool)throws->TextureLease {
        try session.blur(source,sigma:sigma,noise:noise,scaleX:scaleX,scaleY:scaleY,integrated:integrated)
    }
}
