import Foundation
import Metal
import ImagingCore

/// Immutable upload, independent of creative parameters and device white balance/matrix.
public final class PreparedLUT:@unchecked Sendable {
    public let digest:String,deviceID:UInt64
    public let boundaryPolicy: LUTBoundaryPolicy
    package let texture:MTLTexture
    let rangeProof: LUTRangeProof
    package var isExactIdentity: Bool { rangeProof.isExactIdentity }
    private init(digest:String,texture:MTLTexture,rangeProof: LUTRangeProof,device:MTLDevice,boundaryPolicy:LUTBoundaryPolicy) {
        self.boundaryPolicy=boundaryPolicy
        self.digest=digest;self.texture=texture;self.rangeProof=rangeProof;deviceID=device.registryID
    }
    public static func prepare(_ asset:LUTAsset,device:MTLDevice) throws -> PreparedLUT {
        let cube=try asset.decodedCube()
        let d=MTLTextureDescriptor();d.textureType = .type3D;d.pixelFormat = .rgba32Float
        d.width=cube.size;d.height=cube.size;d.depth=cube.size;d.storageMode = .shared;d.usage = .shaderRead
        guard let t=device.makeTexture(descriptor:d) else {throw LabError.io("无法分配 LUT 内存")}
        cube.rgba.withUnsafeBytes{t.replace(region:MTLRegionMake3D(0,0,0,cube.size,cube.size,cube.size),mipmapLevel:0,slice:0,withBytes:$0.baseAddress!,bytesPerRow:cube.size*16,bytesPerImage:cube.size*cube.size*16)}
        return PreparedLUT(digest:asset.sha256,texture:t,rangeProof:LUTRangeProof(cube),device:device,boundaryPolicy:asset.boundaryPolicy)
    }
}
