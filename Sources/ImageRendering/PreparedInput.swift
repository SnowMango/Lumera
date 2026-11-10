import Foundation
import CoreImage
import CoreVideo
import ImageIO
import Metal
import ImagingCore

/// 外部提供的像素在输入准备结束前应保持不变；照片快照保留此源时，不可变期延续至快照释放。
/// JPEG/HEIF 传入已解码的 CIImage，并在配方声明基础图像或增益图重建。
public enum SourceImage: @unchecked Sendable {
    public enum InputDevelopment: String, Codable, Sendable { case decodedPixels, rawDevelopment }
    case image(CIImage, metadata: [String: Any]? = nil, orientation: CGImagePropertyOrientation? = nil)
    case pixelBuffer(CVPixelBuffer, metadata: [String: Any]? = nil, orientation: CGImagePropertyOrientation? = nil)
    case rawURL(URL)
    case rawData(Data)

    package var knownResidentBytes: Int {
        switch self {
        case .rawData(let data): return data.count
        case .pixelBuffer(let buffer, _, _): return CVPixelBufferGetDataSize(buffer)
        case .image, .rawURL: return 0
        }
    }

    public var inputDevelopment: InputDevelopment {
        switch self {
        case .image, .pixelBuffer: return .decodedPixels
        case .rawURL, .rawData: return .rawDevelopment
        }
    }
}

/// 已统一方向和颜色、由渲染模块创建并持有像素的校正前图像。
public final class NormalizedInput: @unchecked Sendable {
    let texture: MTLTexture
    let properties: [String: Any]
    public let descriptor: SourceDescriptor
    public let inputDevelopment: SourceImage.InputDevelopment
    /// 解码器及其最终采用设置的记录，供校正匹配与来源身份计算使用。
    public let effectiveRecipe: EffectiveInputRecipe
    public let working: WorkingImageContract
    public let execution: ExecutionProfile
    /// 实测存储纹理的编码 sRGB 通道范围，EDR 可超出 0…1。
    public let valueBounds: NumericBounds
    public let captureConditions: CaptureConditions
    /// 绑定声明来源、有效配方与工作契约的内容身份。
    public let sourceID: String
    /// 用于绑定具体输入实例的身份。
    public let inputID: String
    public var width: Int { texture.width }
    public var height: Int { texture.height }
    public var image: CIImage { makeInputImage(texture, properties: properties, range: execution.dynamicRange) }
    init(texture: MTLTexture, properties: [String: Any], descriptor: SourceDescriptor, recipe: EffectiveInputRecipe,
         working: WorkingImageContract, execution: ExecutionProfile, bounds: NumericBounds, conditions: CaptureConditions,
         inputDevelopment: SourceImage.InputDevelopment) throws {
        self.texture = texture; self.properties = properties; self.descriptor = descriptor; self.effectiveRecipe = recipe
        self.inputDevelopment = inputDevelopment
        self.working = working; self.execution = execution; self.valueBounds = bounds; self.captureConditions = conditions
        sourceID = try descriptor.contentIdentity(effectiveRecipeDigest: recipe.digest(), working: working)
        inputID = UUID().uuidString
    }
}

/// 输入校正阶段生成的不可变图像与校正身份，可直接用于观测和帧渲染。
public final class PreparedInput: @unchecked Sendable {
    let texture: MTLTexture
    let properties: [String: Any]
    public let source: NormalizedInput
    /// 绑定声明来源、有效配方与工作契约的内容身份。
    public let sourceID: String
    /// 用于绑定具体输入实例的身份。
    public let inputID: String
    /// 所选输入校正（含资格声明）或未验证恒等参考的内容身份。
    public let calibrationID: String
    public let working: WorkingImageContract
    /// 实测存储纹理的编码 sRGB 通道范围，EDR 可超出 0…1。
    public let valueBounds: NumericBounds
    public let captureConditions: CaptureConditions
    /// 其拍摄条件均被当前输入满足的校正资格。
    public let qualifications: [CalibrationQualification]
    public var width: Int { texture.width }
    public var height: Int { texture.height }
    /// 所持有的输入与校正输出实际分配量，共用纹理只计一次。
    public var residentStorageBytes: Int { texture.allocatedSize + (texture === source.texture ? 0 : source.texture.allocatedSize) }
    public var execution: ExecutionProfile { source.execution }
    public var image: CIImage { makeInputImage(texture, properties: properties, range: execution.dynamicRange) }
    /// Copy decision and replay facts without retaining the prepared textures.
    package func photoFacts(stamp: FrameStamp) throws -> FrameInputFacts {
        let recipe = source.effectiveRecipe
        return FrameInputFacts(stamp: stamp, inputID: inputID, sourceID: sourceID, calibrationID: calibrationID,
                               effectiveRecipeDigest: try recipe.digest(), captureConditions: captureConditions, effectiveRecipe: recipe)
    }

    init(texture: MTLTexture, source: NormalizedInput, calibrationID: String, working: WorkingImageContract,
         bounds: NumericBounds, qualifications: [CalibrationQualification]) {
        self.texture = texture; self.source = source; self.properties = source.properties; self.sourceID = source.sourceID
        self.calibrationID = calibrationID; self.working = working; self.valueBounds = bounds
        self.captureConditions = source.captureConditions; self.qualifications = qualifications
        inputID = Digest.data(Data((source.inputID + ":" + calibrationID).utf8))
    }
}
private func makeInputImage(_ texture: MTLTexture, properties: [String: Any], range: ModelDynamicRange) -> CIImage {
    var options: [CIImageOption: Any] = [.colorSpace: LumeraRenderer.colorSpace(for: range == .edr ? .edr : .sdr)]
    if #available(iOS 18, macOS 15, *), range == .edr { options[.contentHeadroom] = 0 }
    // 发布输入前已校验分配和尺寸。
    return CIImage(mtlTexture: texture, options: options)!.settingProperties(LumeraImageMetadata.output(properties,
        width: texture.width, height: texture.height, depth: texture.pixelFormat == .rgba16Float ? 16 : 32, dynamicRange: range == .edr ? .edr : .sdr))
}
