import Metal
import ImagingCore

struct NoiseKey: Equatable {
    let width:Int, height:Int
    let seed:UInt32
    let lumaSigma:Double, chromaSigma:Double
}
struct EffectNoiseField<Surface> { let key:NoiseKey; let luma:Surface, chroma:Surface }
/// 为统一效果顺序提供后端的纹理表示、工作存储和单次效果调度。
protocol EffectPipelineBackend: AnyObject {
    associatedtype Surface: AnyObject
    var noise: EffectNoiseField<Surface>? { get set }
    func texture(_ surface:Surface) -> MTLTexture
    func pass(_ name:String,_ source:Surface,_ extras:[Surface],_ parameters:[Float],size:(Int,Int)?,weights:MTLBuffer?,lut:MTLTexture?,lutTextures:[MTLTexture]) throws -> Surface
    func blur(_ source:Surface,_ sigma:Double,noise:Bool,scaleX:Double,scaleY:Double,integrated:Bool) throws -> Surface
    func opticalGeometry(_ resolution:EffectResolution,frame:RenderGeometry) -> OpticalGrid
    /// 通知后端该次使用结束，具体存储复用时机由后端决定。
    func release(_ surface:Surface)
    func didPrepareCorrection()
    func clearNoise()
}

extension EffectPipelineBackend { func didPrepareCorrection() {} }
