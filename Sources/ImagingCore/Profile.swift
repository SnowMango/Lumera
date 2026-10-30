import Foundation
import CryptoKit

public enum LabError: Error, LocalizedError {
    case invalid(String), unsupported(String), noMetal, measurement(String), io(String)
    public var errorDescription: String? {
        switch self {
        case .invalid(let s), .unsupported(let s), .measurement(let s), .io(let s): return s
        case .noMetal: return "无法使用 Metal 图像处理设备"
        }
    }
    public var exitCode: Int32 {
        switch self { case .invalid: return 2; case .unsupported: return 3; case .noMetal: return 4; case .measurement: return 5; case .io: return 1 }
    }
}
public struct Profile: Codable, Equatable, Sendable {
    public static let engineVersion = "lumera-7.0.0"
    public var schemaVersion = 7
    public var id = UUID().uuidString
    public var name = "标准风格"
    public var description = "中性起点；不对应已标定机型"
    public var parameters = StyleParameters()
    public var responses:[ConditionBinding]=[]
    public var temporalPolicy=TemporalPolicy()
    public var renderContractVersion=1,spatialScaleVersion=1
    public init() {}
    public static var standard: Profile { Profile() }
    public func validate() throws {
        guard schemaVersion == 7 else { throw LabError.invalid("当前开发版只支持风格格式 7，不转换旧配置") }
        guard !id.isEmpty, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LabError.invalid("风格标识与名称不能为空")
        }
        guard renderContractVersion==1,spatialScaleVersion==1 else {throw LabError.invalid("不支持的渲染/空间尺度合同版本")}
        try parameters.validate()
        try StyleEvaluator.validateResponses(responses,parameters:parameters)
    }
    public func effectDigest() throws -> String {
        struct EffectContent:Encodable {let parameters:StyleParameters;let responses:[ConditionBinding];let temporalPolicy:TemporalPolicy;let renderContractVersion:Int;let spatialScaleVersion:Int}
        return Digest.data(try JSON.encode(EffectContent(parameters:parameters,responses:responses,temporalPolicy:temporalPolicy,renderContractVersion:renderContractVersion,spatialScaleVersion:spatialScaleVersion)))
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, id, name, description, parameters, responses, temporalPolicy, renderContractVersion, spatialScaleVersion }
    public init(from decoder: Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        schemaVersion=try c.decode(Int.self,forKey:.schemaVersion)
        guard schemaVersion == 7 else { throw LabError.invalid("当前开发版只支持风格格式 7，不转换旧配置") }
        id=try c.decode(String.self,forKey:.id)
        name=try c.decode(String.self,forKey:.name)
        description=try c.decode(String.self,forKey:.description)
        let legacy=try c.superDecoder(forKey:.parameters).container(keyedBy:RemovedLUTKey.self)
        guard !legacy.contains(.lut) else {throw LabError.invalid("配置不能内嵌 LUT；请通过独立资源输入")}
        parameters=try c.decode(StyleParameters.self,forKey:.parameters)
        responses=try c.decode([ConditionBinding].self,forKey:.responses)
        temporalPolicy=try c.decode(TemporalPolicy.self,forKey:.temporalPolicy)
        renderContractVersion=try c.decode(Int.self,forKey:.renderContractVersion)
        spatialScaleVersion=try c.decode(Int.self,forKey:.spatialScaleVersion)
        try validate()
    }
}

public enum JSON {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; return try e.encode(value)
    }
    public static func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T { try JSONDecoder().decode(type, from: Data(contentsOf: url)) }
}
public enum Digest {
    /// Hash immutable pixel storage without allocating a full-size Data copy.
    public static func buffer(_ bytes:UnsafeRawBufferPointer) -> String {
        var hash=SHA256();hash.update(bufferPointer:bytes)
        return hash.finalize().map{String(format:"%02x",$0)}.joined()
    }
    public static func data(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

private enum RemovedLUTKey:String,CodingKey {case lut}
