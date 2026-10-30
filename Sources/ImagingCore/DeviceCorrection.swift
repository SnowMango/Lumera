import Foundation

/// Independent correction for an already normalized encoded-sRGB SDR input.
/// Selection by camera, lens or capture mode belongs to the caller.
public struct DeviceCorrection: Codable, Equatable, Sendable {
    public var whiteBalance=WhiteBalanceCorrection()
    public var matrix=ColorMatrix3x3()
    public init() {}
    private enum CodingKeys:String,CodingKey {case whiteBalance,matrix}
    private enum RemovedKey:String,CodingKey {case lut}
    public init(from decoder:Decoder) throws {
        let old=try decoder.container(keyedBy:RemovedKey.self)
        guard !old.contains(.lut) else {throw LabError.invalid("设备矫正配置不能内嵌 LUT；请通过独立资源输入")}
        let c=try decoder.container(keyedBy:CodingKeys.self)
        whiteBalance=try c.decode(WhiteBalanceCorrection.self,forKey:.whiteBalance)
        matrix=try c.decode(ColorMatrix3x3.self,forKey:.matrix)
        try validate()
    }
    public func validate() throws {
        var p=StyleParameters();p.color.whiteBalance=whiteBalance;p.color.matrix=matrix
        try p.validate()
    }
    public func effectDigest() throws -> String {try validate();return Digest.data(try JSON.encode(self))}
}
