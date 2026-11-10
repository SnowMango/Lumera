import Foundation

/// 有限数值的闭区间，包含两个端点。
public struct NumericBounds: Codable, Equatable, Sendable {
    public var lower: Double, upper: Double
    public init(lower: Double, upper: Double) { self.lower = lower; self.upper = upper }
    public func validate() throws {
        guard lower.isFinite, upper.isFinite, lower <= upper else { throw LabError.invalid("Invalid numeric bounds") }
    }
    public func contains(_ value: Double) -> Bool { value.isFinite && value >= lower && value <= upper }
}
public enum PixelValueBounds: Codable, Equatable, Sendable { case unknown, finite(NumericBounds) }
public enum ModelDynamicRange: String, Codable, Sendable { case sdr, edr }

/// Describes source provenance. RAW and ProRAW describe capture origin, including
/// when the caller supplies pixels developed outside Lumera.
public struct SourceDescriptor: Codable, Equatable, Sendable {
    public enum Path: String, Codable, Sendable { case processedPhoto, raw, proRAW, videoYUV, externalTexture, unknown }
    public var id: String
    public var device: String?
    public var camera: String?
    public var path: Path
    public var recipeID: String?
    public var primaries: InputDescriptor.Primaries = .unknown
    public var transfer: InputDescriptor.Transfer = .unknown
    public var reference: InputDescriptor.Reference = .unknown
    public var range: PixelValueBounds = .unknown
    public init(id: String, path: Path = .unknown) { self.id = id; self.path = path }
    /// Content identity shared by pixel preparation and package replay validation.
    public func contentIdentity(effectiveRecipeDigest: String, working: WorkingImageContract) throws -> String {
        try validate(); try validateDigest(effectiveRecipeDigest)
        struct Identity: Encodable { let source: SourceDescriptor; let recipe: String; let working: String }
        return Digest.data(try JSON.encode(Identity(source: self, recipe: effectiveRecipeDigest, working: working.digest())))
    }
    public func validate() throws {
        guard !id.isEmpty else { throw LabError.invalid("Source identity is required") }
        if case .finite(let bounds) = range { try bounds.validate() }
    }
}

/// Defaults/permissions only. The selected backend must validate support before development.
public struct RAWSetting: Codable, Equatable, Sendable {
    public enum Key: String, Codable, Sendable { case noiseReduction, luminanceNoiseReduction, colorNoiseReduction, sharpness, exposureEV, temperatureKelvin, tint }
    public var key: Key
    public var value: Double
    public var allowsUserOverride: Bool
    public init(key: Key, value: Double, allowsUserOverride: Bool = false) {
        self.key = key; self.value = value; self.allowsUserOverride = allowsUserOverride
    }
}
/// 由调用方声明的开发或解码配方；实际使用的后端版本和设置见 `EffectiveInputRecipe`。
public struct InputRecipe: Codable, Equatable, Sendable {
    /// Choice made by the caller while decoding a processed image. No custom gain-map reconstruction.
    public enum DecodedRendition: String, Codable, Sendable { case baseImage, systemReconstructed }
    public var id: String, backend: String, version: String
    public var rawSettings: [RAWSetting] = []
    public var decoderVersion: String?
    public var decodedRendition: DecodedRendition?
    public init(id: String, backend: String, version: String, decodedRendition: DecodedRendition? = nil) {
        self.id = id; self.backend = backend; self.version = version; self.decodedRendition = decodedRendition
    }
    public func validate() throws {
        guard !id.isEmpty, !backend.isEmpty, !version.isEmpty,
              Set(rawSettings.map(\.key)).count == rawSettings.count,
              rawSettings.allSatisfy({ $0.value.isFinite }) else { throw LabError.invalid("Invalid input recipe") }
    }
    public func digest() throws -> String { try validate(); return try StyleIdentity.digest(self) }
}

/// Pixel representation and frozen reference rendition are distinct from source camera identity.
public struct WorkingImageContract: Codable, Equatable, Sendable {
    public var version = 1
    public var referenceRenditionID: String
    public var referenceRecipeVersion = "1"
    public var primaries: InputDescriptor.Primaries = .sRGB
    public var whitePoint: Chromaticity = .d65
    public var transfer: InputDescriptor.Transfer = .sRGB
    public var reference: InputDescriptor.Reference = .display
    public var dynamicRange: ModelDynamicRange = .sdr
    /// 工作像素域中参考白的数值，默认 1。
    public var referenceWhite = 1.0
    public var valueBounds: PixelValueBounds = .finite(.init(lower: 0, upper: 1))
    public var alphaMode: InputDescriptor.AlphaMode = .opaque
    public var orientationNormalized = true
    public var fullFrame = true
    public var renditionSemantics = "frozen reference; preserve scene exposure and white balance"
    public init(referenceRenditionID: String) { self.referenceRenditionID = referenceRenditionID }
    public func validate() throws {
        guard version == 1, !referenceRenditionID.isEmpty, !referenceRecipeVersion.isEmpty,
              primaries == .sRGB, transfer == .sRGB, reference == .display,
              referenceWhite.isFinite, referenceWhite > 0, alphaMode == .opaque,
              orientationNormalized, fullFrame, !renditionSemantics.isEmpty else {
            throw LabError.invalid("Unsupported working image contract")
        }
        try whitePoint.validate()
        if case .finite(let bounds) = valueBounds { try bounds.validate() }
    }
    public func digest() throws -> String { try validate(); return try StyleIdentity.digest(self) }
}
/// 按领域和适用条件范围引用输入校准证据。
public struct CalibrationQualification: Codable, Equatable, Sendable {
    public enum Domain: String, Codable, Sendable { case colorTone, texture, temporal }
    public var domain: Domain
    public var evidenceDigest: String
    public var conditionRanges: [ConditionRange]
    public init(domain: Domain, evidenceDigest: String, conditionRanges: [ConditionRange] = []) {
        self.domain = domain; self.evidenceDigest = evidenceDigest; self.conditionRanges = conditionRanges
    }
    public func validate() throws { try validateDigest(evidenceDigest); try ConditionRange.validate(conditionRanges) }
}
/// 条件轴原始单位下的闭区间；插值坐标转换由响应轴另行处理。
public struct ConditionRange: Codable, Equatable, Sendable {
    public var axis: ConditionAxis
    public var bounds: NumericBounds
    public init(axis: ConditionAxis, bounds: NumericBounds) { self.axis = axis; self.bounds = bounds }
    public static func validate(_ values: [Self]) throws {
        guard Set(values.map(\.axis)).count == values.count else { throw LabError.invalid("Duplicate condition ranges") }
        for value in values { try value.bounds.validate(); try value.axis.validate(value.bounds.lower); try value.axis.validate(value.bounds.upper) }
    }
}
/// 把指定来源和配方的图像映射到冻结的工作图像契约，并附上独立资质证据。
public struct InputCalibration: Codable, Equatable, Sendable {
    public var id: String
    public var version = 1
    public var source: SourceDescriptor
    public var recipeDigest: String?
    /// Frozen independent reference source and effective development identity.
    public var referenceDigest: String?
    public var working: WorkingImageContract
    public var correction = DeviceCorrection()
    public var tone: ResponseCurve = .identity
    public var resources: [ModelResourceDescriptor] = []
    public var qualifications: [CalibrationQualification] = []
    public init(id: String, source: SourceDescriptor, working: WorkingImageContract) {
        self.id = id; self.source = source; self.working = working
    }
    public func validate() throws {
        guard !id.isEmpty, version == 1 else { throw LabError.invalid("Invalid calibration identity/version") }
        try source.validate(); try working.validate(); try correction.validate(); try tone.validate(kind: .tone)
        if let recipeDigest { try validateDigest(recipeDigest) }
        if let referenceDigest { try validateDigest(referenceDigest) }
        try ModelResourceDescriptor.validate(resources)
        guard Set(qualifications.map(\.domain)).count == qualifications.count else { throw LabError.invalid("Duplicate qualification domain") }
        for qualification in qualifications { try qualification.validate() }
    }
    public static func unqualifiedReferenceIdentity(working: WorkingImageContract) throws -> String {
        Digest.data(Data(("unqualified-reference:" + (try working.digest())).utf8))
    }
    /// Processing subject excludes evidence attachments, avoiding a self-referential evidence identity.
    public func processingDigest() throws -> String {
        var processing = self
        processing.qualifications = []
        return try processing.digest()
    }
    /// 完整校准的内容摘要，包含资质条目及证据摘要。
    public func digest() throws -> String { try validate(); return try StyleIdentity.digest(self) }
}
func validateDigest(_ digest: String) throws {
    guard digest.count == 64, digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
        throw LabError.invalid("Expected a lowercase SHA-256 digest")
    }
}

public struct RAWOverride: Codable, Equatable, Sendable {
    public var key: RAWSetting.Key
    public var value: Double
    public init(key: RAWSetting.Key, value: Double) { self.key = key; self.value = value }
}

/// Identifies the caller's RAW development operation and its frozen input bytes.
public struct RAWDevelopmentIdentity: Codable, Equatable, Sendable {
    public let identifier: String
    public let version: String
    public let payloadDigest: String

    public init(identifier: String, version: String, payloadDigest: String) throws {
        self.identifier = identifier; self.version = version; self.payloadDigest = payloadDigest
        try validate()
    }

    private func validate() throws {
        guard !identifier.isEmpty, !version.isEmpty else { throw LabError.invalid("RAW development identifier and version are required") }
        try validateDigest(payloadDigest)
    }

    public func digest() throws -> String {
        try validate()
        return try StyleIdentity.digest(self)
    }
}

/// Actual backend/version and effective settings are separate from author permissions.
public struct EffectiveInputRecipe: Codable, Equatable, Sendable {
    public var declared: InputRecipe
    public var backendVersion: String
    public var decoderVersion: String?
    public var settings: [RAWSetting]
    /// Receipt for external RAW configuration. Arbitrary filter changes are represented by the caller's payload identity.
    public var externalRAWConfiguration: RAWDevelopmentIdentity?
    public init(declared: InputRecipe, backendVersion: String, decoderVersion: String? = nil, settings: [RAWSetting] = []) {
        self.init(declared: declared, backendVersion: backendVersion, decoderVersion: decoderVersion, settings: settings, externalRAWConfiguration: nil)
    }
    public init(declared: InputRecipe, backendVersion: String, decoderVersion: String? = nil, settings: [RAWSetting] = [],
                externalRAWConfiguration: RAWDevelopmentIdentity?) {
        self.declared = declared; self.backendVersion = backendVersion; self.decoderVersion = decoderVersion; self.settings = settings
        self.externalRAWConfiguration = externalRAWConfiguration
    }
    public func digest() throws -> String {
        try declared.validate()
        guard !backendVersion.isEmpty, Set(settings.map(\.key)).count == settings.count,
              settings.allSatisfy({ $0.value.isFinite }) else { throw LabError.invalid("Invalid effective input recipe") }
        if let externalRAWConfiguration {
            guard decoderVersion != nil, settings.isEmpty, declared.rawSettings.isEmpty, declared.decoderVersion == nil else {
                throw LabError.invalid("External RAW recipe requires an actual decoder and exclusive configuration")
            }
            _ = try externalRAWConfiguration.digest()
        }
        return try StyleIdentity.digest(self)
    }
}
