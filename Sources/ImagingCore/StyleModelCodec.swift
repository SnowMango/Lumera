import Foundation

/// Serialization only. File/resource access belongs to the caller.
public enum StyleModelCodec {
    /// Decode and explicitly request complete configuration diagnostics.
    public static func decodeChecked(_ data: Data) throws -> StyleModel {
        let value = try decode(data)
        try StyleModelCompiler.validate(value)
        return value
    }

    public static let maximumBytes = ProfileCodec.maximumBytes
    /// 检查 JSON 大小和结构（含重复键）后解码；参数诊断由调用方显式请求。
    public static func decode(_ data: Data) throws -> StyleModel {
        try validateStructure(data)
        let model = try JSONDecoder().decode(StyleModel.self, from: data)
        return model
    }
    /// 编码为 JSON 并检查输出大小上限；不隐式执行参数诊断。
    public static func encode(_ model: StyleModel) throws -> Data {
        let data = try JSON.encode(model)
        try validateStructure(data)
        return data
    }

    /// Returns the semantic identity of the persisted format, before migration.
    /// Byte digests must still be verified separately by the enclosing package.
    public static func persistedModelDigest(_ data: Data) throws -> String {
        let model = try decode(data)
        let original = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        if original["schemaVersion"] as? Int == 1 {
            struct LegacyIdentity: Codable {
                let id: String, camera: String, mode: String
                let firmware: String?
                let settings: [String: String]
            }
            let identityData = try JSONSerialization.data(withJSONObject: original["identity"]!)
            let legacy = try JSONDecoder().decode(LegacyIdentity.self, from: identityData)
            var normalized = try JSONSerialization.jsonObject(with: JSON.encode(model)) as! [String: Any]
            normalized["schemaVersion"] = 1
            normalized["identity"] = try JSONSerialization.jsonObject(with: JSON.encode(legacy))
            let tree = try JSONDecoder().decode(ProfileValue.self, from: JSONSerialization.data(withJSONObject: normalized))
            return try StyleIdentity.digest(tree)
        }
        return try model.digest()
    }

    /// Shared by typed validation and untrusted JSON decoding; no model decoding or validation here.
    static func validateStructure(_ data: Data) throws {
        guard data.count <= maximumBytes else { throw LabError.invalid("Style model exceeds byte budget") }
        var scanner = JSONStructureScanner(bytes: Array(data))
        try scanner.check()
    }
}
