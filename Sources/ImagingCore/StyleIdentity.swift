import Foundation

/// Canonical content encoding is independent of the persisted JSON layout. Object keys
/// are sorted, collections are counted, and all numbers use IEEE-754 binary64 big endian.
public enum StyleIdentity {
    public static func profile(_ profile: Profile) throws -> String {
        try profile.validate()
        struct Content: Encodable {
            let schemaVersion: Int, parameters: StyleParameters
            let responses: [ConditionBinding], temporalPolicy: TemporalPolicy
        }
        return try digest(Content(schemaVersion: profile.schemaVersion, parameters: profile.parameters,
                                  responses: profile.responses.sorted { $0.target.rawValue < $1.target.rawValue },
                                  temporalPolicy: profile.temporalPolicy))
    }

    public static func effective(parameters: StyleParameters, temporalPolicy: TemporalPolicy) throws -> String {
        try parameters.validate(resolved: true)
        struct Content: Encodable { let parameters: StyleParameters, temporalPolicy: TemporalPolicy }
        return try digest(Content(parameters: parameters, temporalPolicy: temporalPolicy))
    }

    static func digest<T: Encodable>(_ content: T) throws -> String {
        let tree = try JSONDecoder().decode(ProfileValue.self, from: JSONEncoder().encode(content))
        var bytes = Data()
        append(tree, to: &bytes)
        return Digest.data(bytes)
    }

    private static func integer(_ value: UInt64, to bytes: inout Data) {
        withUnsafeBytes(of: value.bigEndian) { bytes.append(contentsOf: $0) }
    }
    private static func string(_ value: String, to bytes: inout Data) {
        integer(UInt64(value.utf8.count), to: &bytes)
        bytes.append(contentsOf: value.utf8)
    }
    private static func append(_ value: ProfileValue, to bytes: inout Data) {
        switch value {
        case .object(let fields):
            bytes.append(1); integer(UInt64(fields.count), to: &bytes)
            for key in fields.keys.sorted() {
                string(key, to: &bytes)
                append(fields[key]!, to: &bytes)
            }
        case .array(let values):
            bytes.append(2); integer(UInt64(values.count), to: &bytes)
            for element in values { append(element, to: &bytes) }
        case .string(let value): bytes.append(3); string(value, to: &bytes)
        case .number(let value): bytes.append(4); integer(value == 0 ? 0 : value.bitPattern, to: &bytes)
        case .bool(let value): bytes.append(value ? 5 : 6)
        case .null: bytes.append(7)
        }
    }
}
