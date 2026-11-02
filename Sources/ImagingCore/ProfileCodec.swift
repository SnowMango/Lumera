import Foundation

/// The byte boundary checks constraints that a Codable decoder cannot observe once it has
/// created a keyed container (in particular, duplicate spellings of the same member).
public enum ProfileCodec {
    public static let maximumBytes = 16 * 1024 * 1024

    /// Read at most one byte past the limit, even for a changing or non-seekable file.
    public static func load(from url: URL) throws -> Profile {
        let file = try FileHandle(forReadingFrom:url)
        defer { try? file.close() }
        var data = Data()
        while data.count <= maximumBytes {
            let next = min(64 * 1024, maximumBytes + 1 - data.count)
            guard let chunk = try file.read(upToCount:next), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        return try decode(data)
    }

    public static func decode(_ data: Data) throws -> Profile {
        guard data.count <= maximumBytes else { throw LabError.invalid("$: 超出 16 MiB") }
        var scanner = JSONStructureScanner(bytes: Array(data))
        do {
            try scanner.check()
            return try JSONDecoder().decode(Profile.self, from: data)
        } catch let error as LabError {
            throw error
        } catch let error as DecodingError {
            throw LabError.invalid(error.fieldMessage)
        } catch {
            throw LabError.invalid("$: " + error.localizedDescription)
        }
    }

    public static func encode(_ profile: Profile) throws -> Data {
        try profile.validate()
        let data = try JSON.encode(profile)
        guard data.count <= maximumBytes else { throw LabError.invalid("$: 超出 16 MiB") }
        return data
    }

    static func decodeFields(from decoder: Decoder) throws -> Profile {
        let value = try ProfileValue(from: decoder)
        guard case .object(let fields) = value else { throw LabError.invalid("$: 需要对象") }
        guard fields["schemaVersion"] == .number(8) else {
            throw LabError.invalid("$.schemaVersion: 仅支持格式 8；旧格式请使用独立升级脚本")
        }
        for key in ["id", "name"] where fields[key] == nil { throw LabError.invalid("$.\(key): 缺少字段") }
        let completed = try complete(value, defaults: defaults, path: "$")
        let data = try JSONEncoder().encode(completed)
        // Decode individual fields to retain Codable's enum and array element validation
        // without recursively invoking Profile.init(from:).
        struct Fields: Decodable {
            var id: String, name: String, description: String, parameters: StyleParameters
            var responses: [ConditionBinding], temporalPolicy: TemporalPolicy
        }
        let parsed: Fields
        do { parsed = try JSONDecoder().decode(Fields.self, from: data) }
        catch let error as DecodingError { throw LabError.invalid(error.fieldMessage) }
        // Validate the serialized values before the editable profile limits exposure.
        try parsed.parameters.validate()
        var p = Profile()
        p.id = parsed.id; p.name = parsed.name; p.description = parsed.description
        p.parameters = parsed.parameters; p.responses = parsed.responses; p.temporalPolicy = parsed.temporalPolicy
        try p.validate()
        return p
    }

    // These prototypes come from schema 8's public defaults. The dynamic array/enum cases
    // below describe required structure even where the default value is an empty array.
    private static let defaults = ProfileValue.prototype(Profile())
    private static let function = ProfileValue.prototype(CurveFunction(family: .linear))
    private static let point = ProfileValue.prototype(ResponseKnot(x: 0, y: 0))
    private static let binding = ProfileValue.prototype(ConditionBinding(
        target: .grainSize, axis: .iso, operation: .replace, curve: .identity))

    private static func complete(_ input: ProfileValue, defaults: ProfileValue, path: String) throws -> ProfileValue {
        switch (input, defaults) {
        case (.object(let fields), .object(var output)):
            if path.hasSuffix(".shape") {
                guard fields.count == 1, let (variant, payload) = fields.first else {
                    throw LabError.invalid("\(path): 需要且只能有一种曲线")
                }
                let template: ProfileValue
                switch variant {
                case "function": template = .object(["_0": output["function"]?.object?["_0"] ?? function])
                case "points": template = .object(["_0": .array([]), "interpolation": .string("linear")])
                default: throw LabError.invalid("\(path).\(variant): 未知曲线类型")
                }
                guard payload.object?["_0"] != nil else { throw LabError.invalid("\(path).\(variant)._0: 缺少字段") }
                return .object([variant: try complete(payload, defaults: template, path: path + "." + variant)])
            }
            for (key, value) in fields {
                let childPath = path + "." + key
                guard let childDefault = output[key] else { throw LabError.invalid("\(childPath): 未知字段") }
                output[key] = try complete(value, defaults: childDefault, path: childPath)
            }
            return .object(output)
        case (.array(let values), .array(let prototypes)):
            let prototype: ProfileValue
            let required: [String]
            if path == "$.responses" { prototype = binding; required = ["target","operation","axis","curve"] }
            else if path.hasSuffix(".points._0") { prototype = point; required = ["x","y"] }
            else if let first = prototypes.first { prototype = first; required = [] }
            else { throw LabError.invalid("\(path): 未知数组") }
            return try .array(values.enumerated().map { index, value in
                let elementPath = "\(path)[\(index)]"
                for field in required where value.object?[field] == nil {
                    throw LabError.invalid("\(elementPath).\(field): 缺少字段")
                }
                return try complete(value, defaults: prototype, path: elementPath)
            })
        case (.string, .string), (.bool, .bool), (.number, .number): return input
        default: throw LabError.invalid("\(path): 字段类型错误或为 null")
        }
    }
}

enum ProfileValue: Codable, Equatable {
    case object([String: ProfileValue]), array([ProfileValue]), string(String), number(Double), bool(Bool), null

    var object: [String:ProfileValue]? { if case .object(let fields) = self { return fields }; return nil }
    static func prototype<T: Encodable>(_ value: T) -> Self {
        // Internal, statically constructed schema values always encode as finite JSON.
        try! JSONDecoder().decode(Self.self, from: JSONEncoder().encode(value))
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self), v.isFinite { self = .number(v) }
        else if let v = try? c.decode([Self].self) { self = .array(v) }
        else { self = .object(try c.decode([String:Self].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}

private extension DecodingError {
    var fieldMessage: String {
        let context: Context
        switch self {
        case .dataCorrupted(let c), .keyNotFound(_, let c), .typeMismatch(_, let c), .valueNotFound(_, let c): context = c
        @unknown default: return localizedDescription
        }
        let path = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
        return "$" + path + ": " + context.debugDescription
    }
}

private struct JSONStructureScanner {
    let bytes: [UInt8]
    var offset = 0
    var current: UInt8? { offset < bytes.count ? bytes[offset] : nil }

    mutating func check() throws {
        try value(path: "$", depth: 0)
        skipWhitespace()
        guard current == nil else { throw LabError.invalid("$: 多余的 JSON 内容") }
    }

    mutating func value(path: String, depth: Int) throws {
        skipWhitespace()
        switch current {
        case 123, 91:
            guard depth < 64 else { throw LabError.invalid("\(path): JSON 深度超过 64") }
            let object = current == 123
            offset += 1
            skipWhitespace()
            let close: UInt8 = object ? 125 : 93
            if consume(close) { return }
            var keys = Set<String>(), index = 0
            while true {
                let child: String
                if object {
                    let key = try string(path)
                    child = path + "." + key
                    guard keys.insert(key).inserted else { throw LabError.invalid("\(child): 重复 JSON 键") }
                    skipWhitespace()
                    guard consume(58) else { throw LabError.invalid("\(child): 缺少冒号") }
                } else {
                    // The largest legal schema 8 array is a 32-knot curve.
                    guard index < 32 else { throw LabError.invalid("\(path): 数组超过 32 项") }
                    child = "\(path)[\(index)]"
                }
                try value(path: child, depth: depth + 1)
                skipWhitespace()
                if consume(close) { return }
                guard consume(44) else { throw LabError.invalid("\(path): 缺少逗号") }
                skipWhitespace()
                index += 1
            }
        case 34: _ = try string(path)
        default:
            let start = offset
            while let c = current, ![9,10,13,32,44,93,125].contains(c) { offset += 1 }
            guard offset > start else { throw LabError.invalid("\(path): 缺少值") }
            // Check the JSON numeric grammar as well as representability as binary64.
            let token = String(decoding:bytes[start..<offset],as:UTF8.self)
            guard ["null","true","false"].contains(token) ||
                  (try? JSONDecoder().decode(Double.self, from: Data(bytes[start..<offset])))?.isFinite == true else {
                throw LabError.invalid("\(path): 非法 JSON 值")
            }
        }
    }

    mutating func string(_ path: String) throws -> String {
        let range = try stringRange(path)
        do { return try JSONDecoder().decode(String.self, from: Data(bytes[range])) }
        catch { throw LabError.invalid("\(path): 非法 JSON 字符串") }
    }

    mutating func stringRange(_ path: String) throws -> Range<Int> {
        let start = offset
        guard consume(34) else { throw LabError.invalid("\(path): 需要 JSON 字符串") }
        while let c = current {
            offset += 1
            if c == 34 { return start..<offset }
            if c == 92, current != nil { offset += 1 }
        }
        throw LabError.invalid("\(path): 字符串未结束")
    }

    mutating func consume(_ byte: UInt8) -> Bool {
        guard current == byte else { return false }
        offset += 1
        return true
    }
    mutating func skipWhitespace() { while let c = current, [9,10,13,32].contains(c) { offset += 1 } }
}
