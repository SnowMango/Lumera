import Foundation
import ImagingCore

/// 训练集估计参数，调优集用于筛选或评估候选，验收集留给独立验证。场景、序列及相同文件内容均不得跨集合。
public enum CalibrationSplit: String, Codable, CaseIterable, Sendable { case train, tune, acceptance }

/// 按项目文件所在目录解析路径，使用 SHA-256 与字节数固定文件内容。
public struct CalibrationFile: Codable, Equatable, Sendable {
    public let path: String
    public let sha256: String
    public let byteCount: Int
    public init(path: String, sha256: String, byteCount: Int) {
        self.path = path; self.sha256 = sha256; self.byteCount = byteCount
    }
}
/// 在目标图像的归一化坐标中标记不参与比较的矩形，并记录排除原因。
public struct SampleExclusion: Codable, Equatable, Sendable {
    public let x: Double, y: Double, width: Double, height: Double
    public let reason: String
    public init(x: Double, y: Double, width: Double, height: Double, reason: String) {
        self.x = x; self.y = y; self.width = width; self.height = height; self.reason = reason
    }
}
public struct SampleAlignment: Codable, Equatable, Sendable {
    /// 从输入到目标的归一化全帧仿射变换，顺序为 [a, b, c, d, tx, ty]。原点在左下，项目需显式记录恒等变换。
    public let inputToTarget: [Double]
    public let exclusions: [SampleExclusion]
    public let notes: String?
    public init(inputToTarget: [Double] = [1, 0, 0, 1, 0, 0], exclusions: [SampleExclusion] = [], notes: String? = nil) {
        self.inputToTarget = inputToTarget; self.exclusions = exclusions; self.notes = notes
    }
}
/// 单帧的时序声明。呈现时间、持续时间及采集延迟以秒计。
public struct SampleTiming: Codable, Equatable, Sendable {
    public let frameIndex: UInt64
    public let presentationTime: Double
    public let duration: Double
    public let targetPresentationTime: Double?
    public let captureDelaySeconds: Double?
    public init(frameIndex: UInt64, presentationTime: Double, duration: Double,
                targetPresentationTime: Double? = nil, captureDelaySeconds: Double? = nil) {
        self.frameIndex = frameIndex; self.presentationTime = presentationTime; self.duration = duration
        self.targetPresentationTime = targetPresentationTime; self.captureDelaySeconds = captureDelaySeconds
    }
}
/// 一组按场景或序列归属的数据，分别记录输入和目标的拍摄条件。
public struct CalibrationSample: Codable, Equatable, Sendable {
    public let id: String
    public let input: CalibrationFile
    /// 目标外观图像，用于拟合或验证渲染输出。
    public let target: CalibrationFile
    /// 独立冻结的工作空间参考图像，用于输入校准。目标外观图像不可代替它。
    public let reference: CalibrationFile?
    public let sceneID: String
    public let sequenceID: String?
    public let split: CalibrationSplit
    public let alignment: SampleAlignment
    public let sourceConditions: CaptureConditions
    public let targetConditions: CaptureConditions
    public let timing: SampleTiming?
    public let captureNotes: String?
    public init(id: String, input: CalibrationFile, target: CalibrationFile, reference: CalibrationFile? = nil, sceneID: String,
                sequenceID: String? = nil, split: CalibrationSplit, alignment: SampleAlignment = .init(),
                sourceConditions: CaptureConditions = .init(), targetConditions: CaptureConditions = .init(),
                timing: SampleTiming? = nil, captureNotes: String? = nil) {
        self.id = id; self.input = input; self.target = target; self.reference = reference; self.sceneID = sceneID; self.sequenceID = sequenceID
        self.split = split; self.alignment = alignment; self.sourceConditions = sourceConditions
        self.targetConditions = targetConditions; self.timing = timing; self.captureNotes = captureNotes
    }
}
/// 制作阶段的项目定义，固定输入、目标、样本和验证策略。原始图像路径留在制作项目中。
public struct CalibrationProject: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    private var originalFormatDigest: String? = nil
    public let id: String
    public let target: ModelIdentity
    public let source: SourceDescriptor
    public let inputRecipe: InputRecipe?
    public let working: WorkingImageContract
    public let samples: [CalibrationSample]
    public let validationPolicy: ValidationPolicy
    public let authorizationSource: String?
    /// 输入校准资格声明覆盖的条件轴。未指定时仍可拟合，资格只覆盖实际声明并测量的轴。
    public let inputQualificationAxes: [ConditionAxis]?
    public init(schemaVersion: Int = 2, id: String, target: ModelIdentity, source: SourceDescriptor,
                inputRecipe: InputRecipe?, working: WorkingImageContract, samples: [CalibrationSample],
                validationPolicy: ValidationPolicy = .init(), authorizationSource: String? = nil, inputQualificationAxes: [ConditionAxis]? = nil) {
        self.schemaVersion = schemaVersion; self.id = id; self.target = target; self.source = source
        self.inputRecipe = inputRecipe; self.working = working; self.samples = samples
        self.validationPolicy = validationPolicy; self.authorizationSource = authorizationSource
        self.inputQualificationAxes = inputQualificationAxes
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.schemaVersion == rhs.schemaVersion &&
        lhs.id == rhs.id &&
        lhs.target == rhs.target &&
        lhs.source == rhs.source &&
        lhs.inputRecipe == rhs.inputRecipe &&
        lhs.working == rhs.working &&
        lhs.samples == rhs.samples &&
        lhs.validationPolicy == rhs.validationPolicy &&
        lhs.authorizationSource == rhs.authorizationSource &&
        lhs.inputQualificationAxes == rhs.inputQualificationAxes
    }
    // All project fields are immutable, so this original identity cannot outlive a content edit.
    public func persistedDigest() throws -> String {
        if let originalFormatDigest { return originalFormatDigest }
        return Digest.data(try JSON.encode(self))
    }
    public func matchesDigest(_ digest: String) throws -> Bool {
        if digest == (try persistedDigest()) { return true }
        return digest == Digest.data(try JSON.encode(self))
    }
    private struct LegacyIdentity: Codable {
        let id: String, camera: String, mode: String
        let firmware: String?
        let settings: [String: String]
    }
    private struct LegacyProject: Codable {
        let schemaVersion: Int
        let id: String
        let target: LegacyIdentity
        let source: SourceDescriptor
        let inputRecipe: InputRecipe?
        let working: WorkingImageContract
        let samples: [CalibrationSample]
        let validationPolicy: ValidationPolicy
        let authorizationSource: String?
        let inputQualificationAxes: [ConditionAxis]?
    }
    private enum NeutralIdentityKeys: String, CodingKey { case name, metadata, camera, mode, firmware, settings }
    private enum CodingKeys: String, CodingKey { case schemaVersion, id, target, source, inputRecipe, working, samples, validationPolicy, authorizationSource, inputQualificationAxes }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard [1, 2].contains(version) else { throw LabError.invalid("Unsupported project schema") }
        if version == 2 {
            let identity = try c.nestedContainer(keyedBy: NeutralIdentityKeys.self, forKey: .target)
            _ = try identity.decode(String.self, forKey: .name)
            guard !identity.contains(.camera), !identity.contains(.mode), !identity.contains(.firmware), !identity.contains(.settings) else {
                throw LabError.invalid("Schema 2 requires neutral identity fields")
            }
        }
        if version == 1 {
            let identity = try c.nestedContainer(keyedBy: NeutralIdentityKeys.self, forKey: .target)
            _ = try identity.decode(String.self, forKey: .camera)
            _ = try identity.decode(String.self, forKey: .mode)
            guard !identity.contains(.name), !identity.contains(.metadata) else {
                throw LabError.invalid("Schema 1 requires legacy identity fields")
            }
        }
        schemaVersion = 2
        id = try c.decode(String.self, forKey: .id)
        target = try c.decode(ModelIdentity.self, forKey: .target)
        source = try c.decode(SourceDescriptor.self, forKey: .source)
        inputRecipe = try c.decodeIfPresent(InputRecipe.self, forKey: .inputRecipe)
        working = try c.decode(WorkingImageContract.self, forKey: .working)
        samples = try c.decode([CalibrationSample].self, forKey: .samples)
        validationPolicy = try c.decode(ValidationPolicy.self, forKey: .validationPolicy)
        authorizationSource = try c.decodeIfPresent(String.self, forKey: .authorizationSource)
        inputQualificationAxes = try c.decodeIfPresent([ConditionAxis].self, forKey: .inputQualificationAxes)
        if version == 1 { originalFormatDigest = Digest.data(try JSON.encode(LegacyProject(from: decoder))) }
    }
    public func encode(to encoder: Encoder) throws {
        guard schemaVersion == 2 else { throw LabError.invalid("Only schema 2 can be encoded") }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(2, forKey: .schemaVersion)
        try c.encode(id, forKey: .id)
        try c.encode(target, forKey: .target)
        try c.encode(source, forKey: .source)
        try c.encodeIfPresent(inputRecipe, forKey: .inputRecipe)
        try c.encode(working, forKey: .working)
        try c.encode(samples, forKey: .samples)
        try c.encode(validationPolicy, forKey: .validationPolicy)
        try c.encodeIfPresent(authorizationSource, forKey: .authorizationSource)
        try c.encodeIfPresent(inputQualificationAxes, forKey: .inputQualificationAxes)
    }

}
