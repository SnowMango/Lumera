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
        try Task.checkCancellation(); try descriptor.validate(); try recipe.validate(); try execution.validate()
        guard descriptor.recipeID == recipe.id, recipe.backend == "coreImage", working.dynamicRange == execution.dynamicRange,
              renderer.imageInputFormat == (execution.precision == .float16 ? .rgba16Float : .rgba32Float) else {
            throw LabError.invalid("Input recipe, working range or renderer precision mismatch")
        }
        let range: RenderDynamicRange = execution.dynamicRange == .edr ? .edr : .sdr
        var effective = EffectiveInputRecipe(declared: recipe, backendVersion: ProcessInfo.processInfo.operatingSystemVersionString)
        let image: CIImage, metadata: [String: Any]?, orientation: CGImagePropertyOrientation?
        var sourceFacts: [String: Any]?
        var bufferOutputProperties: [String: Any]?
        var raw: CIRAWFilter?
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
            raw = filter
            let decoded = try renderer.developRAW(filter, dynamicRange: range) { try Self.configure($0, recipe: recipe, overrides: rawOverrides, effective: &effective) }
            image = decoded.image; metadata = decoded.properties; orientation = .up
        case .rawData(let data):
            guard let filter = CIRAWFilter(imageData: data, identifierHint: nil) else { throw LabError.unsupported("Unsupported RAW bytes") }
            raw = filter
            let decoded = try renderer.developRAW(filter, dynamicRange: range) { try Self.configure($0, recipe: recipe, overrides: rawOverrides, effective: &effective) }
            image = decoded.image; metadata = decoded.properties; orientation = .up
        }
        if raw == nil {
            guard recipe.rawSettings.isEmpty, recipe.decoderVersion == nil, rawOverrides.isEmpty,
                  descriptor.path != .raw, descriptor.path != .proRAW else { throw LabError.invalid("RAW recipe requires RAW development input") }
        } else {
            guard descriptor.path == .raw || descriptor.path == .proRAW else { throw LabError.invalid("RAW input path must be explicitly identified") }
        }
        let normalized = try renderer.normalizedSource(image, metadata: metadata, orientation: orientation, dynamicRange: range)
        let width = Int(normalized.bounds.width), height = Int(normalized.bounds.height)
        try TextureDimensions.validate(width: width, height: height, device: renderer.device)
        let bytes = try ImageDimensions.pixelCount(width: width, height: height) * execution.precision.bytesPerPixel
        guard bytes <= execution.budget.maxResidentBytes / 2 else { throw LabError.invalid("Normalized input exceeds execution memory budget") }
        _ = try await renderer.measureInputRange(normalized.image, bounds: normalized.bounds, colorSpace: LumeraRenderer.colorSpace(for: range),
            budget: min(64 * 1024 * 1024, execution.budget.maxResidentBytes - bytes), requireHalf: execution.precision == .float16)
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: renderer.imageInputFormat, width: width, height: height, mipmapped: false)
        textureDescriptor.storageMode = .private; textureDescriptor.usage = [.shaderRead, .shaderWrite]
        guard let texture = renderer.device.makeTexture(descriptor: textureDescriptor), let command = renderer.queue.makeCommandBuffer() else { throw LabError.io("Cannot allocate normalized input") }
        renderer.context.render(normalized.image, to: texture, commandBuffer: command, bounds: normalized.bounds, colorSpace: LumeraRenderer.colorSpace(for: range))
        // Core Image 的内部精度可能随输出格式改变，因此从实际写入的纹理读取数值范围。
        let readback = try renderer.rangeReducer.encode(texture, commandBuffer: command)
        try await renderer.complete(command)
        let bounds = try readback.resolve()
        var properties = [CFString: Any]()
        for (key, value) in (sourceFacts ?? normalized.properties) { properties[key as CFString] = value }
        return try NormalizedInput(texture: texture, properties: bufferOutputProperties ?? normalized.properties, descriptor: descriptor, recipe: effective,
                                   working: working, execution: execution, bounds: bounds, conditions: InputCaptureMetadataReader.read(properties: properties))
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
