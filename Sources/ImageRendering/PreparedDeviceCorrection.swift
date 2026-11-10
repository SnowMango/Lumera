import Foundation
import Metal
import ImagingCore

/// 绑定 Metal 设备的前置颜色变换与 LUT 快照，可在帧循环外准备并独立于创意风格复用。
public final class PreparedDeviceCorrection: @unchecked Sendable {
    public let digest:String
    public let color:PreparedColorTransform
    public let colorIsActive:Bool
    let lut: PreparedLUT?
    package var lutTexture: MTLTexture? { lut?.texture }
    package var lutBoundaryPolicy: LUTBoundaryPolicy { lut?.boundaryPolicy ?? .automatic }
    public let deviceID:UInt64
    private init(digest:String,color:PreparedColorTransform,active:Bool,lut:PreparedLUT?,device:MTLDevice) {
        self.digest=digest;self.color=color;colorIsActive=active;self.lut=lut;deviceID=device.registryID
    }
    /// 用户输入曝光和白平衡编辑复用前置颜色变换，位于已完成输入校正之后。
    static func inputEdit(_ response: ColorResponse, device: MTLDevice) throws -> PreparedDeviceCorrection? {
        let color = try ColorTransform.prepare(response)
        guard response.isActive else { return nil }
        return PreparedDeviceCorrection(digest: "frame-input-edit", color: color, active: true, lut: nil,
            device: device)
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
        // Retain explicitly clamped identity LUTs: they still bound EDR inputs.
        // Automatic identity retains the legacy SDR no-op and is also identity under EDR extrapolation.
        if !response.isActive,preparedLUT == nil || (preparedLUT!.isExactIdentity && preparedLUT!.boundaryPolicy != .clamp) {return nil}
        let digest=try correction.effectDigest()
        return PreparedDeviceCorrection(digest:preparedLUT.map{Digest.data(Data((digest+":"+$0.digest+($0.boundaryPolicy == .automatic ? "" : ":"+$0.boundaryPolicy.rawValue)).utf8))} ?? digest,
            color:color,active:response.isActive,lut:preparedLUT,device:device)
    }
}
