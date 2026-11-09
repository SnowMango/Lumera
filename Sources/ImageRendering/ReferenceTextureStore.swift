import Foundation
import Metal
import ImagingCore

struct InputKey:Hashable {let address:UInt;let width:Int,height:Int;var limit:Int?=nil;var correctionDigest:String?=nil}
final class CachedInput {
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
struct CachedPrefix {let key:PrefixKey;let image:TextureLease;let layer:TextureLease?}
struct PrefixKey:Equatable {
    let color:ColorResponse,tone:ToneResponse,detail:Detail,softening:Softening,vignette:Vignette,glow:Glow,halation:Halation
    let lut:String?,previewGlow:Bool
    let glowScale:EffectResolution,halationScale:EffectResolution,softeningScale:EffectResolution
    init(parameters p:StyleParameters,lut:String?,previewGlow:Bool,glowScale:EffectResolution,halationScale:EffectResolution,softeningScale:EffectResolution) {
        self.glowScale=glowScale;self.halationScale=halationScale;self.softeningScale=softeningScale
        color=p.color;tone=p.tone;detail=p.detail;softening=p.softening;vignette=p.vignette
        glow=p.glow;halation=p.halation;self.lut=lut;self.previewGlow=previewGlow
    }
}
// 输入、前缀或后续读取仍持有租约时，纹理保持占用。
// 归还后由 Metal 的资源依赖跟踪保护已编码的读取。
final class TextureLease {
    let texture:MTLTexture
    let pool:TexturePool
    var width:Int {texture.width};var height:Int {texture.height}
    init(_ texture:MTLTexture,pool:TexturePool){self.texture=texture;self.pool=pool}
    deinit {pool.recycle(texture)}
}
/// 串行参考会话的空闲 Float32 纹理池，容量约束作用于已归还的纹理。
final class TexturePool {
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

