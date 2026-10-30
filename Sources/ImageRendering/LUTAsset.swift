import Foundation
import ImagingCore

public enum LUTContent:String,Sendable {case colorOnly,colorAndTone,unspecified}
public struct LUTAsset:Equatable,Sendable {
    public var name:String,cubeText:String,sha256:String
    private var rawCube:CubeLUT?
    private var rawDigest:String?
    /// Canonical samples are immutable; no text roundtrip is needed for GPU upload.
    init(name:String,cube:CubeLUT) {
        self.name=name;cubeText="";rawCube=cube
        var identity=Data("RGBA32-LUT:\(cube.size):encoded-sRGB:".utf8)
        cube.rgba.withUnsafeBytes{identity.append(contentsOf:$0)}
        sha256=Digest.data(identity);rawDigest=sha256
    }
    package func decodedCube() throws -> CubeLUT {
        try validate();return try rawCube ?? CubeLUT.parse(cubeText)
    }
    public var content:LUTContent = .unspecified
    public var contract="encoded-sRGB-to-encoded-sRGB"
    public init(name:String,cubeText:String) {self.name=name;self.cubeText=cubeText;self.sha256=Digest.data(Data(cubeText.utf8))}
    public func validate() throws {
        if rawCube != nil {
            guard contract == "encoded-sRGB-to-encoded-sRGB",cubeText.isEmpty,sha256==rawDigest else {throw LabError.invalid("LUT 内容或颜色约定已被修改")}
            return
        }
        guard contract == "encoded-sRGB-to-encoded-sRGB",!cubeText.isEmpty,cubeText.utf8.count<=16_000_000,
              sha256 == Digest.data(Data(cubeText.utf8)) else {throw LabError.invalid("LUT 输入输出域或内容摘要无效")}
    }
}
/// Explicit caller-owned resources, never serialized into a Profile or DeviceCorrection.
public struct RenderResources:Equatable,Sendable {
    public var lut:LUTAsset?,correctionLUT:LUTAsset?
    public init(lut:LUTAsset?=nil,correctionLUT:LUTAsset?=nil) {self.lut=lut;self.correctionLUT=correctionLUT}
    public func validate() throws {try lut?.validate();try correctionLUT?.validate()}
}
