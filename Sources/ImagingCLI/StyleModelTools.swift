import Foundation
import CoreImage
import Metal
import ImagingCore
import ImageRendering
import ImageAnalysis
import ImagingRuntime

/// File paths and GPU creation stay in the CLI adapter, never in Core authoring math.
/// CLI 文件适配配置；路径留在命令层，传给拟合器/渲染器的是已校验资源值。
private struct ModelToolSettings: Codable {
    enum CalibrationMode: String, Codable { case provided, identityReference, fitReference }
    let model: StyleModel
    let execution: ExecutionProfile
    let resources: [String: String]?
    let inputResources: [String: String]?
    let calibration: InputCalibration?
    let calibrationMode: CalibrationMode?
    let targetSource: SourceDescriptor?
    let targetRecipe: InputRecipe?
    let referenceSource: SourceDescriptor?
    let referenceRecipe: InputRecipe?
    let referenceAlignments: [String: SampleAlignment]?
    let appearanceOptions: AppearanceFitOptions?
    let inputFitOptions: FitOptions?
    let conditionFitOptions: FitOptions?
    let grayRegions: [String: [Region]]?
    let capturedAuthorizationReference: String?
}
private struct ModelFitSummary: Encodable {
    let algorithm: String
    let packageDigest: String
    let converged: Bool
    let trainMaximumError: Double?
    let tuneMaximumError: Double?
    let unresolved: [String]
    let options: AppearanceFitOptions
}
private struct ModelConditionFitSummary: Encodable {
    let algorithm: String
    let packageDigest: String
    let trainResidual: Double?
    let tuneResidual: Double?
    let unresolved: [String]
    let design: ConditionFitDesign
    let options: FitOptions
    let appearanceOptions: AppearanceFitOptions
    let conditionDomains: [FittedConditionDomain]
    let consumedSampleIDs: [String]
    let measurementDigests: [String]
}
private struct ModelReplayReport: Encodable {
    let mode: String
    let packageDigest: String
    let recordsDigest: String
    let decisions: [FrameDecision]
}

/// 风格模型的构建、前向拟合、独立验证和纯决策回放入口。
/// 文件读取与覆盖保护集中在此，模型编译和拟合仍调用各自模块的共享实现。
enum StyleModelTools {
    /// 参数解析与输出预检完成后进入对应流程；候选包生成不等于效果验证验收通过。
    static func run(_ args: [String]) async throws {
        guard let command = args.first, ["fit", "build", "validate", "replay"].contains(command) else {
            throw LabError.invalid("Expected model fit|build|validate|replay")
        }
        var values = [String: String](), force = false, i = 1
        while i < args.count {
            let key = args[i]
            if key == "--force" { guard !force else { throw LabError.invalid("Duplicate --force") }; force = true; i += 1; continue }
            guard ["--project", "--settings", "--model", "--records", "--output", "--fit-report", "--mode", "--condition-design"].contains(key),
                  values[key] == nil, i + 1 < args.count, !args[i+1].hasPrefix("--") else { throw LabError.invalid("Unknown or duplicated model argument: \(key)") }
            values[key] = args[i+1]; i += 2
        }
        func url(_ key: String) throws -> URL {
            guard let path = values[key], !path.isEmpty else { throw LabError.invalid("Missing \(key)") }
            return URL(fileURLWithPath: path)
        }
        let output = try url("--output")
        // 同时预检包与诊断报告，避免仅因第二个目标已存在而在写完第一个目标后失败。
        for destination in [values["--output"], values["--fit-report"]].compactMap({ $0 }) {
            if !force && FileManager.default.fileExists(atPath: destination) { throw LabError.io("Output already exists; use --force") }
        }
        var protected = try values.filter { ["--project", "--settings", "--model", "--records", "--condition-design"].contains($0.key) }.keys.map(url)
        if command == "replay" {
            guard Set(values.keys).isSubset(of: ["--model", "--records", "--output", "--mode"]), values["--mode"] == nil || values["--mode"] == "automatic" else {
                throw LabError.invalid("Replay mode is automatic; frozen decisions are FrameDecision values, not automatic replay records")
            }
            let package = try JSONDecoder().decode(StyleModelPackage.self, from: boundedRead(url("--model")))
            let loaded = try package.load(), recordBytes = try boundedRead(url("--records"))
            let records = try JSONDecoder().decode([DecisionRecord].self, from: recordBytes)
            // 包级配方/校正身份先校验，随后纯 Runtime 回放只处理可重建决策。
            try package.validateReplayInputs(records)
            let decisions = try DecisionReplay.evaluate(records, model: loaded.compiled)
            try protect(output, inputs: protected)
            try SafeFiles.write(JSON.encode(ModelReplayReport(mode: "automatic", packageDigest: package.digest(), recordsDigest: Digest.data(recordBytes), decisions: decisions)), to: output, overwrite: force)
            print("Replayed \(decisions.count) decisions; no measured qualification granted")
            return
        }
        let projectURL = try url("--project"), settingsURL = try url("--settings")
        let project = try JSONDecoder().decode(CalibrationProject.self, from: boundedRead(projectURL))
        let settings = try JSONDecoder().decode(ModelToolSettings.self, from: boundedRead(settingsURL))
        try settings.execution.validate()
        let validator = DatasetValidator(baseDirectory: projectURL.deletingLastPathComponent())
        let dataset = try validator.validate(project)
        protected += project.samples.flatMap { [$0.input, $0.target] + [$0.reference].compactMap { $0 } }.map(validator.resolve)
        let base = settingsURL.deletingLastPathComponent()
        let paths = Array((settings.resources ?? [:]).values) + Array((settings.inputResources ?? [:]).values)
        protected += paths.map { resolve($0, base: base) }
        try protect(output, inputs: protected)
        if let report = values["--fit-report"] {
            let reportURL = URL(fileURLWithPath: report)
            try protect(reportURL, inputs: protected + [output]); protected.append(reportURL)
        }
        guard let device = MTLCreateSystemDefaultDevice() else { throw LabError.unsupported("Metal is unavailable") }
        let renderer = try LumeraRenderer(device: device, precision: .init(settings.execution.precision))
        if command == "validate" {
            guard Set(values.keys).isSubset(of: ["--project", "--settings", "--model", "--output"]) else { throw LabError.invalid("Unexpected validation option") }
            let package = try JSONDecoder().decode(StyleModelPackage.self, from: boundedRead(url("--model")))
            guard let source = settings.targetSource, let recipe = settings.targetRecipe else { throw LabError.invalid("Validation requires explicit target source/recipe") }
            let provenance: CalibrationEvidenceProvenance = settings.capturedAuthorizationReference.map { .captured(authorizationReference: $0) } ?? .development
            let evaluator = try ModelValidator(renderer: renderer, targetSource: source, targetRecipe: recipe, provenance: provenance)
            let report = try await evaluator.validate(package, dataset: dataset, policy: project.validationPolicy, execution: settings.execution)
            try SafeFiles.write(JSON.encode(report), to: output, overwrite: force)
            print("Validation recorded \(report.measuredDomains.count) measured domains; inspect all domain statuses")
            return
        }
        guard Set(values.keys).isSubset(of: ["--project", "--settings", "--output", "--fit-report", "--condition-design"]) else { throw LabError.invalid("Unexpected build/fit option") }
        // 目标外观与输入校正分别匹配各自声明，避免同名 ID 引用到错误用途的资源。
        let resources = try loadResources(settings.resources ?? [:], descriptors: settings.model.appearance.resources, base: base, budget: settings.execution.budget.maxResidentBytes)
        let inputResources = try loadResources(settings.inputResources ?? [:], descriptors: settings.calibration?.resources ?? [], base: base, budget: settings.execution.budget.maxResidentBytes)
        let builder = try ModelBuilder(renderer: renderer, execution: settings.execution)
        if command == "build" {
            guard values["--fit-report"] == nil, values["--condition-design"] == nil else { throw LabError.invalid("Build does not fit responses or create fit diagnostics") }
            let package = try builder.build(project, model: settings.model, resources: resources, calibration: settings.calibration, inputResources: inputResources)
            try SafeFiles.write(JSON.encode(package), to: output, overwrite: force)
            print("Built manual candidate; measured validation is separate")
            return
        }
        guard let source = settings.targetSource, let targetRecipe = settings.targetRecipe else { throw LabError.invalid("Fit requires explicit target source/recipe") }
        let calibration: InputCalibration
        // 没有独立输入参考时只能显式选恒等参考，不从目标风格照片反推“输入校准”。
        switch settings.calibrationMode ?? .provided {
        case .provided:
            guard let value = settings.calibration else { throw LabError.invalid("Provide input calibration or explicitly select identityReference/fitReference") }; calibration = value
        case .identityReference:
            guard let sample = dataset.samples.first(where: { $0.split == .train }), let recipe = project.inputRecipe else { throw LabError.measurement("Identity reference needs an actual training input and recipe") }
            let bytes = try CalibrationReferenceLoader.checkedBytes(sample.input, baseDirectory: dataset.baseDirectory, maximumBytes: settings.execution.budget.maxResidentBytes / 4)
            let normalized = try await InputAdapter(renderer: renderer, working: project.working).prepare(sourceImage(bytes, descriptor: project.source, recipe: recipe), descriptor: project.source, recipe: recipe, execution: settings.execution)
            calibration = try InputCalibrationSolver.identity(source: project.source, effectiveRecipe: normalized.effectiveRecipe, reference: project.working)
        case .fitReference:
            guard let referenceSource = settings.referenceSource, let recipe = settings.referenceRecipe, let alignments = settings.referenceAlignments else {
                throw LabError.invalid("Reference calibration requires separate reference source, recipe and alignments")
            }
            let loader = try CalibrationReferenceLoader(renderer: renderer, execution: settings.execution, working: project.working,
                referenceSource: referenceSource, referenceRecipe: recipe, referenceAlignments: alignments, resources: inputResources)
            calibration = try await InputCalibrationSolver(loader: loader).solve(dataset, reference: project.working, options: settings.inputFitOptions ?? .init())
        }
        let fixed = settings.model.appearance.lutWeights.first.flatMap { resources.luts[$0.resourceID] }
        let prediction = try ReferenceAppearancePredictor(renderer: MetalRenderer(device: device), fixedLUT: fixed)
        let loader = try AppearanceDatasetLoader(renderer: renderer, execution: settings.execution, working: project.working,
            targetSource: source, targetRecipe: targetRecipe, grayRegions: settings.grayRegions ?? [:])
        // 条件拟合的复杂度由训练/调参数据决定；验收样本留给独立 validate 流程。
        if values["--condition-design"] != nil {
            let design = try JSONDecoder().decode(ConditionFitDesign.self, from: boundedRead(url("--condition-design")))
            let options = settings.conditionFitOptions ?? FitOptions()
            let appearanceOptions = settings.appearanceOptions ?? AppearanceFitOptions()
            let scorer = try B7ResponseScorer(renderer: renderer, working: project.working, execution: settings.execution, resources: resources)
            let fit = try await ResponseFitter.fit(dataset, baseline: settings.model, calibration: calibration, resources: resources,
                inputResources: inputResources, design: design, options: options, appearanceOptions: appearanceOptions,
                loader: loader, predictor: prediction, scorer: scorer)
            let package = try builder.build(project, fit: fit, inputResources: inputResources)
            try Task.checkCancellation()
            try SafeFiles.write(JSON.encode(package), to: output, overwrite: force)
            if let path = values["--fit-report"] {
                let report = ModelConditionFitSummary(algorithm: fit.algorithmVersion, packageDigest: try package.digest(),
                    trainResidual: fit.trainResidual, tuneResidual: fit.tuneResidual, unresolved: fit.unresolved, design: design,
                    options: options, appearanceOptions: appearanceOptions, conditionDomains: fit.conditionDomains,
                    consumedSampleIDs: fit.consumedSampleIDs, measurementDigests: fit.measurementDigests)
                try SafeFiles.write(JSON.encode(report), to: URL(fileURLWithPath: path), overwrite: force)
            }
            print("Built conditional candidate; unmeasured domains remain unqualified")
            return
        }
        let fit = try await AppearanceFitter.fit(dataset, calibration: calibration, baseline: settings.model, resources: resources,
            options: settings.appearanceOptions ?? .init(), loader: loader, predictor: prediction, inputResources: inputResources)
        let modelFit = try ModelFitResult.constant(base: fit, baseline: settings.model, resources: resources, calibration: calibration)
        let package = try builder.build(project, fit: modelFit, inputResources: inputResources)
        let data = try JSON.encode(package)
        try Task.checkCancellation()
        try SafeFiles.write(data, to: output, overwrite: force)
        if let path = values["--fit-report"] {
            let report = ModelFitSummary(algorithm: fit.algorithmVersion, packageDigest: try package.digest(), converged: fit.converged,
                trainMaximumError: fit.trainMaximumError, tuneMaximumError: fit.tuneMaximumError, unresolved: fit.unresolved, options: fit.options)
            try SafeFiles.write(JSON.encode(report), to: URL(fileURLWithPath: path), overwrite: force)
        }
        print("Built fitted candidate; full-scene and independent captured validation remain separate")
    }
    private static func resolve(_ path: String, base: URL) -> URL { path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path) }
    /// 读取前后检查字节上限；后一次检查覆盖检查与读取之间文件增长的情形。
    private static func boundedRead(_ url: URL, limit: Int = 256 * 1024 * 1024) throws -> Data {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attrs[.size] as? NSNumber, size.intValue <= limit else { throw LabError.invalid("Input file exceeds CLI byte limit") }
        let bytes = try Data(contentsOf: url)
        guard bytes.count <= limit else { throw LabError.invalid("Input grew beyond CLI byte limit") }
        return bytes
    }
    /// 即使允许覆盖，也禁止输出路径与项目、设置、资源或样本的规范路径重合。
    private static func protect(_ output: URL, inputs: [URL]) throws {
        let canonical = output.resolvingSymlinksInPath().standardizedFileURL
        guard !inputs.contains(where: { $0.resolvingSymlinksInPath().standardizedFileURL == canonical }) else { throw LabError.invalid("Refusing to overwrite an input file") }
    }
    /// 文件映射必须精确匹配声明目录，逐项校验摘要并累计读取预算，不接受额外隐式资源。
    private static func loadResources(_ paths: [String: String], descriptors: [ModelResourceDescriptor], base: URL, budget: Int) throws -> ModelResourceSet {
        guard Set(paths.keys) == Set(descriptors.map(\.id)) else { throw LabError.invalid("Resource file map differs from declared catalog") }
        var luts = [String: LUTAsset](), curves = [String: ResponseCurve](), consumed = 0
        for descriptor in descriptors {
            let bytes = try boundedRead(resolve(paths[descriptor.id]!, base: base), limit: budget - consumed); consumed += bytes.count
            guard Digest.data(bytes) == descriptor.sha256 else { throw LabError.invalid("Resource file digest mismatch") }
            if descriptor.role == .toneCurve { curves[descriptor.id] = try JSONDecoder().decode(ResponseCurve.self, from: bytes) }
            else { guard let text = String(data: bytes, encoding: .utf8) else { throw LabError.invalid("LUT must be UTF8") }; luts[descriptor.id] = .init(name: descriptor.id, cubeText: text) }
        }
        return try .init(luts: luts, curves: curves)
    }
    /// 保留 RAW 原始字节交给输入适配器；已处理照片按明确 rendition 解码，方向由后续统一处理。
    private static func sourceImage(_ bytes: Data, descriptor: SourceDescriptor, recipe: InputRecipe) throws -> SourceImage {
        if descriptor.path == .raw || descriptor.path == .proRAW { return .rawData(bytes) }
        guard descriptor.path == .processedPhoto, let rendition = recipe.decodedRendition,
              let image = CIImage(data: bytes, options: [.applyOrientationProperty: false, .expandToHDR: rendition == .systemReconstructed]) else {
            throw LabError.unsupported("CLI file input requires explicit processed-photo or RAW development")
        }
        return .image(image)
    }
}
