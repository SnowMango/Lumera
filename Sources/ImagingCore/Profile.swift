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
/// Attach a stable member path to failures from validators reused outside profile decoding.
func validateField(_ path: String, _ check: () throws -> Void) throws {
    do { try check() }
    catch { throw LabError.invalid("\(path): \(error.localizedDescription)") }
}

public struct Profile: Codable, Equatable, Sendable {
    public var schemaVersion = LumeraVersion.schemaVersion
    public var id = UUID().uuidString
    public var name = "标准风格"
    public var description = "中性起点；手动参数，未附测量证据"
    public var parameters = StyleParameters() {
        didSet { parameters.color.exposureEV = ColorResponse.limitedExposure(parameters.color.exposureEV) }
    }
    public var responses:[ConditionBinding]=[]
    public var temporalPolicy=TemporalPolicy()
    public init() {}
    public static var standard: Profile { Profile() }
    public func validate() throws {
        guard schemaVersion == LumeraVersion.schemaVersion else {
            throw LabError.invalid("$.schemaVersion: 不支持此格式，请使用独立升级脚本")
        }
        guard !id.isEmpty else { throw LabError.invalid("$.id: 标识不能为空") }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LabError.invalid("$.name: 名称不能为空")
        }
        try parameters.validate()
        try StyleEvaluator.validateResponses(responses,parameters:parameters)
    }
    public func effectDigest() throws -> String {
        try StyleIdentity.profile(self)
    }
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, description, parameters, responses, temporalPolicy
    }
    public init(from decoder: Decoder) throws {
        self = try ProfileCodec.decodeFields(from: decoder)
    }

}

public enum JSON {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; return try e.encode(value)
    }
    public static func load(_ type: Profile.Type, from url: URL) throws -> Profile {
        try ProfileCodec.load(from: url)
    }
    public static func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        if T.self == Profile.self, let profile = try ProfileCodec.load(from:url) as? T { return profile }
        return try JSONDecoder().decode(type, from: Data(contentsOf:url))
    }
}
public enum Digest {
    /// Hash immutable pixel storage without allocating a full-size Data copy.
    public static func buffer(_ bytes:UnsafeRawBufferPointer) -> String {
        var hash=SHA256();hash.update(bufferPointer:bytes)
        return hash.finalize().map{String(format:"%02x",$0)}.joined()
    }
    public static func data(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
