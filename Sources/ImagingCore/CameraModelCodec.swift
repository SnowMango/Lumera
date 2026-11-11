import Foundation

/// Serialization only. File/resource access belongs to the caller.
public enum CameraModelCodec {
    public static let maximumBytes = ProfileCodec.maximumBytes
    /// 先检查原始 JSON 的大小和结构（含重复键），再解码并验证模型声明。
    public static func decode(_ data: Data) throws -> CameraModel {
        try validateStructure(data)
        let model = try JSONDecoder().decode(CameraModel.self, from: data)
        try model.validate()
        return model
    }
    /// 先验证模型声明，再编码为 JSON 并检查输出大小上限。
    public static func encode(_ model: CameraModel) throws -> Data {
        try model.validate()
        let data = try JSON.encode(model)
        guard data.count <= maximumBytes else { throw LabError.invalid("Camera model exceeds byte budget") }
        return data
    }

    /// Shared by typed validation and untrusted JSON decoding; no model decoding or validation here.
    static func validateStructure(_ data: Data) throws {
        guard data.count <= maximumBytes else { throw LabError.invalid("Camera model exceeds byte budget") }
        var scanner = JSONStructureScanner(bytes: Array(data))
        try scanner.check()
    }
}
