import Foundation
import CoreImage
import ImagingCore

/// Replayable RAW development supplied by the host. The identifier and version
/// identify the operation, and the payload must encode every setting it applies.
public struct RAWDevelopmentConfiguration: Sendable {
    public let identity: RAWDevelopmentIdentity
    public let payload: Data
    private let operation: @Sendable (CIRAWFilter, Data) throws -> Void

    /// Apply receives the live decoder after Lumera sets its defaults and before it requests
    /// output. Use immutable captures and deterministic behavior. Keep the filter within
    /// the callback and change the version when the operation's meaning changes.
    public init(identifier: String, version: String, payload: Data,
                apply: @escaping @Sendable (CIRAWFilter, Data) throws -> Void) throws {
        let frozen = payload.withUnsafeBytes { Data($0) }
        self.payload = frozen
        identity = try .init(identifier: identifier, version: version, payloadDigest: Digest.data(frozen))
        operation = apply
    }

    func apply(to filter: CIRAWFilter) throws {
        try operation(filter, payload)
    }
}
