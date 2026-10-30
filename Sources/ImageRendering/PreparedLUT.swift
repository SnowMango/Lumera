import Foundation
import Metal
import ImagingCore

/// Immutable upload, independent of creative parameters and device white balance/matrix.
public final class PreparedLUT:@unchecked Sendable {
    public let digest:String,deviceID:UInt64
    package let texture:MTLTexture
    package let isExactIdentity:Bool
    private init(digest:String,texture:MTLTexture,identity:Bool,device:MTLDevice) {
        self.digest=digest;self.texture=texture;isExactIdentity=identity;deviceID=device.registryID
    }
    public static func prepare(_ asset:LUTAsset,device:MTLDevice) throws -> PreparedLUT {
        let cube=try asset.decodedCube()
        let d=MTLTextureDescriptor();d.textureType = .type3D;d.pixelFormat = .rgba32Float
        d.width=cube.size;d.height=cube.size;d.depth=cube.size;d.storageMode = .shared;d.usage = .shaderRead
        guard let t=device.makeTexture(descriptor:d) else {throw LabError.io("无法分配 LUT 内存")}
        cube.rgba.withUnsafeBytes{t.replace(region:MTLRegionMake3D(0,0,0,cube.size,cube.size,cube.size),mipmapLevel:0,slice:0,withBytes:$0.baseAddress!,bytesPerRow:cube.size*16,bytesPerImage:cube.size*cube.size*16)}
        var identity=true
        for b in 0..<cube.size {for g in 0..<cube.size {for r in 0..<cube.size {
            let i=((b*cube.size+g)*cube.size+r)*4
            if cube.rgba[i] != Float(r)/Float(cube.size-1) || cube.rgba[i+1] != Float(g)/Float(cube.size-1) || cube.rgba[i+2] != Float(b)/Float(cube.size-1) {identity=false}
        }}}
        return PreparedLUT(digest:asset.sha256,texture:t,identity:identity,device:device)
    }
}
