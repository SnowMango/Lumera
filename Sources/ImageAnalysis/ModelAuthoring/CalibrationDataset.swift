import Foundation

public struct CalibrationBaselineAvailability: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case insufficient }
    public enum Metric: String, Codable, CaseIterable, Sendable {
        case inputColor, grayScale, highlights, skinAndSaturatedColors, texture, temporalResidual
    }
    public let metric: Metric
    public let status: Status
    public let value: Double?
    public let reason: String
}
/// 记录文件和元数据是否齐备，供后续制作使用。实拍资格另由独立测量给出。
public struct CalibrationCheckReport: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case incomplete, readyForDevelopment }
    public let schemaVersion: Int
    public let projectID: String
    public let projectDigest: String
    public let recipeDigest: String
    public let workingDigest: String
    public let status: Status
    public let sampleCounts: [String: Int]
    public let missingInformation: [String]
    public let baselines: [CalibrationBaselineAvailability]
}
/// 已校验的项目元数据快照。读取像素时仍需复核文件字节身份。
public struct CalibrationDataset: Sendable {
    public let project: CalibrationProject
    public var samples: [CalibrationSample] { project.samples }
    public let baseDirectory: URL
    public let report: CalibrationCheckReport
    init(project: CalibrationProject, baseDirectory: URL, report: CalibrationCheckReport) {
        self.project = project; self.baseDirectory = baseDirectory; self.report = report
    }
}
