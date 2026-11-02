import Foundation

/// A caller's optional associations. Identifiers are labels, never paths to load.
public struct ResourceReferences: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let id: String
        public let sha256: String
        public let contract: String
        public init(id: String, sha256: String, contract: String) {
            self.id = id
            self.sha256 = sha256
            self.contract = contract
        }
    }
    public var styleLUT: Entry?
    public var deviceCorrection: Entry?
    public var correctionLUT: Entry?
    public init(styleLUT: Entry? = nil, deviceCorrection: Entry? = nil, correctionLUT: Entry? = nil) {
        self.styleLUT = styleLUT
        self.deviceCorrection = deviceCorrection
        self.correctionLUT = correctionLUT
    }
}
