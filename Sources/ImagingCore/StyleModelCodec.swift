import Foundation

/// Serialization only. File/resource access belongs to the caller.
public enum StyleModelCodec {
    public static let maximumBytes = ProfileCodec.maximumBytes
    /// 先检查原始 JSON 的大小和结构（含重复键），再解码并验证模型声明。
    public static func decode(_ data: Data) throws -> StyleModel {
        try validateStructure(data)
        let model = try JSONDecoder().decode(StyleModel.self, from: data)
        try model.validate()
        return model
    }
    /// 先验证模型声明，再编码为 JSON 并检查输出大小上限。
    public static func encode(_ model: StyleModel) throws -> Data {
        try model.validate()
        let data = try JSON.encode(model)
        guard data.count <= maximumBytes else { throw LabError.invalid("Style model exceeds byte budget") }
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
