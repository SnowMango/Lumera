import Foundation
import Metal
import ImagingCore

/// Immutable device-specific resources. Prepare once outside a camera's frame loop.
/// The caller keeps this snapshot separate from a creative style.
public final class PreparedDeviceCorrection: @unchecked Sendable {
    public let digest:String
    public let color:PreparedColorTransform
    public let colorIsActive:Bool
    package let lutTexture:MTLTexture?
    public let deviceID:UInt64
    private init(digest:String,color:PreparedColorTransform,active:Bool,lut:MTLTexture?,device:MTLDevice) {
        self.digest=digest;self.color=color;colorIsActive=active;lutTexture=lut;deviceID=device.registryID
    }
    public static func prepare(_ correction:DeviceCorrection?,lut asset:LUTAsset?=nil,device:MTLDevice) throws -> PreparedDeviceCorrection? {
        try prepare(correction,preparedLUT:asset.map{try PreparedLUT.prepare($0,device:device)},device:device)
    }
    public static func prepare(_ correction:DeviceCorrection?,preparedLUT:PreparedLUT?,device:MTLDevice) throws -> PreparedDeviceCorrection? {
        guard correction != nil || preparedLUT != nil else{return nil}
        guard preparedLUT == nil || preparedLUT!.deviceID==device.registryID else {throw LabError.invalid("LUT 不属于当前 Metal 设备")}
        let correction=correction ?? DeviceCorrection()
        try correction.validate()
        var response=ColorResponse();response.whiteBalance=correction.whiteBalance;response.matrix=correction.matrix
        let color=try ColorTransform.prepare(response)
        // Identity LUT is redundant only while the incoming values remain bounded.
        if !response.isActive,preparedLUT == nil || preparedLUT!.isExactIdentity {return nil}
        let digest=try correction.effectDigest()
        return PreparedDeviceCorrection(digest:preparedLUT.map{Digest.data(Data((digest+":"+$0.digest).utf8))} ?? digest,
            color:color,active:response.isActive,lut:preparedLUT?.texture,device:device)
    }
}
