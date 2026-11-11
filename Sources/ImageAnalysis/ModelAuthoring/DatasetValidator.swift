import Foundation
import CryptoKit
import ImagingCore

/// 检查冻结项目的文件、身份与分组，建立供拟合和验收使用的数据集快照。
public struct DatasetValidator: Sendable {
    public let baseDirectory: URL
    public init(baseDirectory: URL) { self.baseDirectory = baseDirectory.standardizedFileURL }

    public func resolve(_ file: CalibrationFile) -> URL {
        file.path.hasPrefix("/") ? URL(fileURLWithPath: file.path) : baseDirectory.appendingPathComponent(file.path)
    }
    /// 核验项目文件的字节身份、样本元数据和集合边界，返回包含就绪报告的数据集。
    public func validate(_ project: CalibrationProject) throws -> CalibrationDataset {
        guard project.schemaVersion == 2, nonempty(project.id), nonempty(project.target.id),
              nonempty(project.target.name) else {
            throw LabError.invalid("Project schema 2 and model identity are required")
        }
        if let axes = project.inputQualificationAxes, axes.isEmpty || Set(axes).count != axes.count {
            throw LabError.invalid("Input qualification axes must be explicit, nonempty and unique")
        }
        try project.source.validate(); try project.working.validate(); try project.validationPolicy.validate()
        guard project.working.dynamicRange == .sdr else { throw LabError.invalid("Model authoring requires an explicit SDR working reference") }
        guard let recipe = project.inputRecipe else { throw LabError.invalid("Input recipe is required") }
        try recipe.validate()
        guard project.source.recipeID == recipe.id else { throw LabError.invalid("Source input recipe identity does not match") }
        var ids = Set<String>(), scenes = [String: CalibrationSplit](), sequences = [String: CalibrationSplit]()
        var contents = [String: CalibrationSplit](), counts = Dictionary(uniqueKeysWithValues: CalibrationSplit.allCases.map { ($0.rawValue, 0) })
        var frameIDs = Set<String>()
        for sample in project.samples {
            guard nonempty(sample.id), ids.insert(sample.id).inserted, nonempty(sample.sceneID) else { throw LabError.invalid("Missing or duplicate sample identity/scene") }
            try bind(sample.sceneID, split: sample.split, groups: &scenes, kind: "scene")
            if let sequence = sample.sequenceID {
                guard nonempty(sequence) else { throw LabError.invalid("Empty sequence identity") }
                try bind(sequence, split: sample.split, groups: &sequences, kind: "sequence")
            }
            try sample.sourceConditions.validate(); try sample.targetConditions.validate()
            try validateAlignment(sample.alignment)
            if let timing = sample.timing {
                guard let sequence = sample.sequenceID, timing.presentationTime.isFinite,
                      timing.duration.isFinite, timing.duration > 0,
                      timing.targetPresentationTime.map({ $0.isFinite }) ?? true,
                      timing.captureDelaySeconds.map({ $0.isFinite }) ?? true,
                      frameIDs.insert(sequence + ":" + String(timing.frameIndex)).inserted else {
                    throw LabError.invalid("Invalid or duplicate sequence frame timing")
                }
            }
            for file in [sample.input, sample.target] + [sample.reference].compactMap({ $0 }) {
                try validateFile(file)
                try bind(file.sha256, split: sample.split, groups: &contents, kind: "file content")
            }
            counts[sample.split.rawValue, default: 0] += 1
        }
        var missing = [String]()
        if project.samples.isEmpty { missing.append("samples") }
        for split in CalibrationSplit.allCases where counts[split.rawValue] == 0 { missing.append("split." + split.rawValue) }
        if project.validationPolicy.thresholds.isEmpty { missing.append("validationPolicy.thresholds") }
        if !nonempty(project.authorizationSource ?? "") { missing.append("authorizationSource") }
        if project.source.path == .unknown { missing.append("source.path") }
        let baselines = CalibrationBaselineAvailability.Metric.allCases.map {
            CalibrationBaselineAvailability(metric: $0, status: .insufficient, value: nil,
                                            reason: project.samples.isEmpty ? "No real sample measurements available" : "File/metadata check only; pixel measurement has not run")
        }
        let report = CalibrationCheckReport(schemaVersion: 1, projectID: project.id,
                                            projectDigest: try project.persistedDigest(), recipeDigest: try recipe.digest(),
                                            workingDigest: try project.working.digest(), status: missing.isEmpty ? .readyForDevelopment : .incomplete,
                                            sampleCounts: counts, missingInformation: missing, baselines: baselines)
        return CalibrationDataset(project: project, baseDirectory: baseDirectory, report: report)
    }
    private func nonempty(_ value: String) -> Bool { !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private func bind(_ key: String, split: CalibrationSplit, groups: inout [String: CalibrationSplit], kind: String) throws {
        if let previous = groups[key], previous != split { throw LabError.invalid("Same \(kind) cannot cross dataset splits: \(key)") }
        groups[key] = split
    }
    private func validateAlignment(_ alignment: SampleAlignment) throws {
        let t = alignment.inputToTarget
        guard t.count == 6, t.allSatisfy(\.isFinite), (t[0] * t[3] - t[1] * t[2]).isFinite,
              abs(t[0] * t[3] - t[1] * t[2]) > 1e-12 else { throw LabError.invalid("Invalid or singular sample alignment") }
        for region in alignment.exclusions {
            guard [region.x, region.y, region.width, region.height].allSatisfy(\.isFinite),
                  region.x >= 0, region.y >= 0, region.width > 0, region.height > 0,
                  region.x + region.width <= 1, region.y + region.height <= 1, nonempty(region.reason) else {
                throw LabError.invalid("Invalid normalized exclusion region or missing reason")
            }
        }
    }
    private func validateFile(_ file: CalibrationFile) throws {
        guard nonempty(file.path), file.byteCount > 0, file.sha256.count == 64,
              file.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw LabError.invalid("Invalid file path, size or SHA-256 identity")
        }
        let url = resolve(file)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw LabError.invalid("Sample must be a regular file") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256(), count = 0
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            count += chunk.count; hash.update(data: chunk)
        }
        let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard count == file.byteCount, actual == file.sha256 else { throw LabError.invalid("Sample bytes changed: \(file.path)") }
    }
}
