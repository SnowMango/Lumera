import Foundation
import ImagingCore
import ImageAnalysis

/// `camera-project` command arguments, excluding the command name. No rendering/GPU creation.
enum CameraModelCommands {
    /// 仅校验项目结构、分组和文件摘要并写报告；不会拟合像素或授予实拍资格。
    static func run(_ arguments: [String]) throws {
        guard arguments.first == "check" else { throw LabError.invalid("Expected camera-project check") }
        var values = [String: String](), force = false, index = 1
        while index < arguments.count {
            let key = arguments[index]
            if key == "--force" {
                guard !force else { throw LabError.invalid("Duplicate --force") }
                force = true; index += 1; continue
            }
            guard ["--project", "--output"].contains(key), values[key] == nil,
                  index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--"),
                  !arguments[index + 1].isEmpty else { throw LabError.invalid("Unknown, duplicated or incomplete option: \(key)") }
            values[key] = arguments[index + 1]; index += 2
        }
        guard let projectPath = values["--project"], let outputPath = values["--output"] else {
            throw LabError.invalid("camera-project check requires --project and --output")
        }
        let input = URL(fileURLWithPath: projectPath), output = URL(fileURLWithPath: outputPath)
        let project = try JSON.load(CalibrationProject.self, from: input)
        let validator = DatasetValidator(baseDirectory: input.deletingLastPathComponent())
        let protected = [input] + project.samples.flatMap { sample in
            ([sample.input, sample.target] + [sample.reference].compactMap { $0 }).map { validator.resolve($0) }
        }
        // 先解析符号链接和标准路径，避免 --force 通过路径别名覆盖项目或配对原图。
        let canonicalOutput = output.resolvingSymlinksInPath().standardizedFileURL
        guard !protected.contains(where: { $0.resolvingSymlinksInPath().standardizedFileURL == canonicalOutput }) else {
            throw LabError.invalid("Refusing to overwrite an input file")
        }
        let dataset = try validator.validate(project)
        try Task.checkCancellation()
        try SafeFiles.write(JSON.encode(dataset.report), to: output, overwrite: force)
        print("Camera project \(project.id): \(dataset.report.status.rawValue); no measured qualification granted")
    }
}
