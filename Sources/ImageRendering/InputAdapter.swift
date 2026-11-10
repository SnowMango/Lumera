import Foundation
import CoreImage
import CoreVideo
import ImageIO
import Metal
import ImagingCore

/// 统一解释源像素的解码、方向和颜色，产出供后续输入校正使用的图像。
public final class InputAdapter: @unchecked Sendable {
    private let renderer: LumeraRenderer
    private let working: WorkingImageContract
    public init(renderer: LumeraRenderer, working: WorkingImageContract) throws {
        try working.validate()
        guard working.whitePoint == .d65, working.referenceWhite == 1 else { throw LabError.unsupported("Input adapter requires D65 and unit reference white") }
        self.renderer = renderer; self.working = working
    }
    /// 按配方解释完整输入，保留有效解码设置和拍摄事实，并返回所选精度的独立纹理。
    /// RAW 由系统解码，已解码图像的基础图像或增益图重建方式由调用方声明。
    public func prepare(_ source: SourceImage, descriptor: SourceDescriptor, recipe: InputRecipe,
                        execution: ExecutionProfile, rawOverrides: [RAWOverride] = []) async throws -> NormalizedInput {
        try await prepare(source, descriptor: descriptor, recipe: recipe, execution: execution, rawOverrides: rawOverrides, rawConfiguration: nil)
    }

    /// A caller-certified bound on finite RGB after orientation, compositing and color conversion
    /// into the renderer's encoded sRGB working space. Only decoded sources may make this promise.
    /// Half storage still measures the actual pixels and checks the rounded certified interval.
    public func prepare(_ source: SourceImage, descriptor: SourceDescriptor, recipe: InputRecipe,
                        execution: ExecutionProfile, trustedNormalizedRGBBounds: NumericBounds) async throws -> NormalizedInput {
        try await prepare(source, descriptor: descriptor, recipe: recipe, execution: execution,
                          rawOverrides: [], rawConfiguration: nil, trustedNormalizedRGBBounds: trustedNormalizedRGBBounds)
    }

    /// Develops a RAW source with the caller's configuration, or the legacy recipe when the configuration is nil.
    /// Decoded pixels can declare RAW or ProRAW capture origin through the source descriptor.
    public func prepare(_ source: SourceImage, descriptor: SourceDescriptor, recipe: InputRecipe,
                        execution: ExecutionProfile, rawOverrides: [RAWOverride] = [],
                        rawConfiguration: RAWDevelopmentConfiguration?) async throws -> NormalizedInput {
        try await prepare(source, descriptor: descriptor, recipe: recipe, execution: execution,
                          rawOverrides: rawOverrides, rawConfiguration: rawConfiguration, trustedNormalizedRGBBounds: nil)
    }

    func prepare(_ source: SourceImage, descriptor: SourceDescriptor, recipe: InputRecipe,
                 execution: ExecutionProfile, rawOverrides: [RAWOverride], rawConfiguration: RAWDevelopmentConfiguration?,
                 trustedNormalizedRGBBounds: NumericBounds?) async throws -> NormalizedInput {
        try Task.checkCancellation()
        if let bounds = trustedNormalizedRGBBounds {
            try bounds.validate()
            guard source.inputDevelopment == .decodedPixels,
                  execution.precision != .float16 || max(abs(bounds.lower), abs(bounds.upper)) <= 65504 / 1.02 else {
                throw LabError.invalid("Trusted normalized range requires decoded pixels and safe storage bounds")
            }
        }
        let resolved = try resolve(source, descriptor: descriptor, recipe: recipe, execution: execution,
                                   rawOverrides: rawOverrides, rawConfiguration: rawConfiguration)
        return try await resolved.prepare(region: resolved.bounds, execution: execution, trustedNormalizedRGBBounds: trustedNormalizedRGBBounds)
    }

    /// Resolve decoding, orientation and color lazily, before allocating any full-frame texture.
    public func resolve(_ source: SourceImage, descriptor: SourceDescriptor, recipe: InputRecipe,
                        execution: ExecutionProfile, rawOverrides: [RAWOverride] = [],
                        rawConfiguration: RAWDevelopmentConfiguration? = nil) throws -> ResolvedPhotoSource {
        try descriptor.validate(); try recipe.validate(); try execution.validate()
        guard descriptor.recipeID == recipe.id, recipe.backend == "coreImage", working.dynamicRange == execution.dynamicRange,
              renderer.imageInputFormat == (execution.precision == .float16 ? .rgba16Float : .rgba32Float) else {
            throw LabError.invalid("Input recipe, working range or renderer precision mismatch")
        }
        try Self.validateRAWRequest(source, descriptor: descriptor, recipe: recipe, rawOverrides: rawOverrides, rawConfiguration: rawConfiguration)
        let range: RenderDynamicRange = execution.dynamicRange == .edr ? .edr : .sdr
        var effective = EffectiveInputRecipe(declared: recipe, backendVersion: ProcessInfo.processInfo.operatingSystemVersionString)
        func develop(_ filter: CIRAWFilter) throws -> (image: CIImage, properties: [String: Any]) {
            let decoded = try renderer.developRAW(filter, dynamicRange: range) { raw in
                if let rawConfiguration {
                    try rawConfiguration.apply(to: raw)
                } else {
                    try Self.configure(raw, recipe: recipe, overrides: rawOverrides, effective: &effective)
                }
            }
            if let rawConfiguration {
                effective.decoderVersion = filter.decoderVersion.rawValue
                effective.externalRAWConfiguration = rawConfiguration.identity
            }
            return decoded
        }
        let image: CIImage, metadata: [String: Any]?, orientation: CGImagePropertyOrientation?
        var sourceFacts: [String: Any]?
        var bufferOutputProperties: [String: Any]?
        switch source {
        case .image(let value, let properties, let valueOrientation):
            guard let rendition = recipe.decodedRendition else { throw LabError.invalid("Decoded image recipe must declare base image or system reconstruction") }
            if rendition == .systemReconstructed {
                guard #available(iOS 18, macOS 15, *) else { throw LabError.unsupported("System HDR reconstruction requires a supported OS") }
            }
            image = value; metadata = properties; orientation = valueOrientation
        case .pixelBuffer(let buffer, let properties, let valueOrientation):
            let decoded = try renderer.interpretedBuffer(buffer, metadata: properties, orientation: valueOrientation)
            image = decoded.image; metadata = decoded.properties; orientation = decoded.orientation; sourceFacts = decoded.facts; bufferOutputProperties = decoded.properties
        case .rawURL(let url):
            guard url.isFileURL, let filter = CIRAWFilter(imageURL: url) else { throw LabError.unsupported("Unsupported RAW URL") }
            let decoded = try develop(filter)
            image = decoded.image; metadata = decoded.properties; orientation = .up
        case .rawData(let data):
            guard let filter = CIRAWFilter(imageData: data, identifierHint: nil) else { throw LabError.unsupported("Unsupported RAW bytes") }
            let decoded = try develop(filter)
            image = decoded.image; metadata = decoded.properties; orientation = .up
        }
        let normalized = try renderer.normalizedSource(image, metadata: metadata, orientation: orientation, dynamicRange: range)
        var properties = [CFString: Any]()
        for (key, value) in (sourceFacts ?? normalized.properties) { properties[key as CFString] = value }
        return ResolvedPhotoSource(renderer: renderer, image: normalized.image, bounds: normalized.bounds,
            properties: bufferOutputProperties ?? normalized.properties, descriptor: descriptor, recipe: effective,
            working: working, conditions: InputCaptureMetadataReader.read(properties: properties), development: source.inputDevelopment, knownResidentBytes: source.knownResidentBytes)
    }
    /// Validate input mode and RAW controls without opening or developing the source.
    package static func validateRAWRequest(_ source: SourceImage, descriptor: SourceDescriptor, recipe: InputRecipe,
                                           rawOverrides: [RAWOverride], rawConfiguration: RAWDevelopmentConfiguration?) throws {
        let hasLegacyRAWControls = !recipe.rawSettings.isEmpty || recipe.decoderVersion != nil || !rawOverrides.isEmpty
        if rawConfiguration != nil, hasLegacyRAWControls {
            throw LabError.invalid("External RAW configuration and legacy RAW controls cannot be combined")
        }
        switch source.inputDevelopment {
        case .decodedPixels:
            guard rawConfiguration == nil, !hasLegacyRAWControls else { throw LabError.invalid("RAW configuration requires RAW development input") }
        case .rawDevelopment:
            guard descriptor.path == .raw || descriptor.path == .proRAW else { throw LabError.invalid("RAW input path must be explicitly identified") }
        }
    }

    private static func configure(_ raw: CIRAWFilter, recipe: InputRecipe, overrides: [RAWOverride], effective: inout EffectiveInputRecipe) throws {
        if let version = recipe.decoderVersion {
            let selected = CIRAWDecoderVersion(rawValue: version)
            guard raw.supportedDecoderVersions.contains(selected) else { throw LabError.unsupported("Unsupported RAW decoder version") }
            raw.decoderVersion = selected
        }
        var supported: Set<RAWSetting.Key> = [.exposureEV, .temperatureKelvin, .tint]
        var defaults: [RAWSetting] = [.init(key: .exposureEV, value: Double(raw.exposure)), .init(key: .temperatureKelvin, value: Double(raw.neutralTemperature)), .init(key: .tint, value: Double(raw.neutralTint))]
        if raw.isSharpnessSupported { supported.insert(.sharpness); defaults.append(.init(key: .sharpness, value: Double(raw.sharpnessAmount))) }
        if raw.isLuminanceNoiseReductionSupported { supported.insert(.luminanceNoiseReduction); defaults.append(.init(key: .luminanceNoiseReduction, value: Double(raw.luminanceNoiseReductionAmount))) }
        if raw.isColorNoiseReductionSupported { supported.insert(.colorNoiseReduction); defaults.append(.init(key: .colorNoiseReduction, value: Double(raw.colorNoiseReductionAmount))) }
        if raw.isLuminanceNoiseReductionSupported && raw.isColorNoiseReductionSupported { supported.insert(.noiseReduction) }
        let settings = try RAWRecipeResolver.resolve(recipe, overrides: overrides, supported: supported, defaults: defaults)
        for setting in settings {
            let value = Float(setting.value)
            switch setting.key {
            case .exposureEV: raw.exposure = value
            case .temperatureKelvin: raw.neutralTemperature = value
            case .tint: raw.neutralTint = value
            case .sharpness: raw.sharpnessAmount = value
            case .luminanceNoiseReduction: raw.luminanceNoiseReductionAmount = value
            case .colorNoiseReduction: raw.colorNoiseReductionAmount = value
            case .noiseReduction: throw LabError.invalid("Unresolved generic RAW noise setting")
            }
        }
        effective.decoderVersion = raw.decoderVersion.rawValue
        effective.settings = settings.map { setting in
            let value: Float
            switch setting.key {
            case .exposureEV: value = raw.exposure
            case .temperatureKelvin: value = raw.neutralTemperature
            case .tint: value = raw.neutralTint
            case .sharpness: value = raw.sharpnessAmount
            case .luminanceNoiseReduction: value = raw.luminanceNoiseReductionAmount
            case .colorNoiseReduction: value = raw.colorNoiseReductionAmount
            case .noiseReduction: preconditionFailure("Generic control resolved above")
            }
            return .init(key: setting.key, value: Double(value))
        }
        _ = try effective.digest()
    }
}
