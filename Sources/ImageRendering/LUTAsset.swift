import Foundation
import ImagingCore

/// 声明 LUT 内容是否包含色调映射。
public enum LUTContent:String,Sendable {case colorOnly,colorAndTone,unspecified}
/// 携带源样本摘要、编码契约及采样策略的三维 LUT 资源。
public struct LUTAsset:Equatable,Sendable {
    /// 输入越界时的采样策略。源样本及其 SHA-256 摘要保持原值。
    public var boundaryPolicy: LUTBoundaryPolicy = .automatic
    public var name:String,cubeText:String,sha256:String
    private var rawCube:CubeLUT?
    private var rawDigest:String?
    /// 规范化样本直接用于 GPU 上传，省去文本往返。
    init(name:String,cube:CubeLUT) {
        self.name=name;cubeText="";rawCube=cube
        var identity=Data("RGBA32-LUT:\(cube.size):encoded-sRGB:".utf8)
        cube.rgba.withUnsafeBytes{identity.append(contentsOf:$0)}
        sha256=Digest.data(identity);rawDigest=sha256
    }
    /// Bound resource preparation before allocating decoded samples. Values and
    /// complete .cube syntax remain the responsibility of the existing decoder.
    package func preflightDimension(_ expected: Int) throws {
        guard (2...256).contains(expected) else { throw LabError.invalid("Invalid declared LUT dimension") }
        let sampleCount = expected * expected * expected
        if let rawCube {
            guard rawCube.size == expected, rawCube.rgba.count == sampleCount * 4 else {
                throw LabError.invalid("LUT dimension or sample count differs from its descriptor")
            }
            return
        }
        var declared = false, rows = 0, failure: String?
        cubeText.enumerateLines { line, stop in
            let content = line.prefix { $0 != "#" }
            let fields = content.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard let first = fields.first else { return }
            switch first {
            case "LUT_3D_SIZE":
                guard !declared, fields.count == 2,
                      Int(fields[1].trimmingCharacters(in: .whitespaces)) == expected else {
                    failure = "LUT dimension differs from its descriptor"; stop = true; return
                }
                declared = true
            case "TITLE", "DOMAIN_MIN", "DOMAIN_MAX": break
            default:
                rows += 1
                if !declared || rows > sampleCount {
                    failure = "LUT sample count exceeds its descriptor"; stop = true
                }
            }
        }
        guard failure == nil, declared, rows == sampleCount else {
            throw LabError.invalid(failure ?? "LUT dimension or sample count differs from its descriptor")
        }
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
/// 调用方单独提供的渲染资源，按风格和设备校正用途区分。
public struct RenderResources:Equatable,Sendable {
    public var lut:LUTAsset?,correctionLUT:LUTAsset?
    public init(lut:LUTAsset?=nil,correctionLUT:LUTAsset?=nil) {self.lut=lut;self.correctionLUT=correctionLUT}
    public func validate() throws {try lut?.validate();try correctionLUT?.validate()}
}

extension RenderResources {
    public func validate(against references: ResourceReferences, correction: DeviceCorrection? = nil) throws {
        try validate()
        try correction?.validate()
        func check(_ role: String, _ reference: ResourceReferences.Entry?, digest: String?, contract: String) throws {
            guard let reference else { return }
            guard !reference.id.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, reference.contract == contract, let digest,
                  digest == reference.sha256 else {
                throw LabError.invalid("\(role)：缺少资源或资源摘要、契约不匹配（\(reference.id)）")
            }
        }
        try check("styleLUT", references.styleLUT, digest: lut?.sha256, contract: "encoded-sRGB-to-encoded-sRGB")
        try check("correctionLUT", references.correctionLUT, digest: correctionLUT?.sha256, contract: "encoded-sRGB-to-encoded-sRGB")
        try check("deviceCorrection", references.deviceCorrection, digest: correction?.effectDigest(), contract: "linear-sRGB-device-correction")
    }
}
