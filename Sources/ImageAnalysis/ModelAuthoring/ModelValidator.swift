import Foundation
import CoreImage
import ImagingCore
import ImageRendering

/// 对冻结模型包执行独立整场景验收测量。坐标使用 Core Image 左下原点的归一化坐标。
public struct ModelValidator {
    public static let algorithmVersion = "whole-scene-encoded-rgb-v1"
    private let renderer: LumeraRenderer
    private let targetSource: SourceDescriptor
    private let targetRecipe: InputRecipe
    private let provenance: CalibrationEvidenceProvenance
    private let context: CIContext
    public init(renderer: LumeraRenderer, targetSource: SourceDescriptor, targetRecipe: InputRecipe,
                provenance: CalibrationEvidenceProvenance = .development) throws {
        try targetSource.validate(); try targetRecipe.validate()
        guard targetSource.recipeID == targetRecipe.id else { throw LabError.invalid("Target source and decoding recipe differ") }
        self.renderer = renderer; self.targetSource = targetSource; self.targetRecipe = targetRecipe; self.provenance = provenance
        context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
            .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])
    }
    /// 在同帧统计的 SDR 路径渲染验收集，并与目标外观逐像素比较，报告归一化编码 RGB 最大绝对误差。
    /// 其余验证域标记为证据不足。开发数据可用于误差比较，实测域需要实拍目标证据。
    public func validate(_ package: StyleModelPackage, dataset: CalibrationDataset, policy: ValidationPolicy,
                         execution: ExecutionProfile) async throws -> ModelValidationReport {
        try Task.checkCancellation(); try execution.validate(); try policy.validate()
        let loaded = try package.load(), project = dataset.project
        guard execution.dynamicRange == .sdr, project.working.dynamicRange == .sdr else {
            throw LabError.unsupported("Whole-scene encoded RGB validation currently requires SDR input and execution")
        }
        guard package.manifest.preparedFor == execution, policy == project.validationPolicy,
              try project.matchesDigest(package.manifest.projectDigest),
              dataset.report.projectDigest == (try project.persistedDigest()),
              loaded.model.identity == project.target, package.manifest.source == project.source,
              package.manifest.recipe == project.inputRecipe, package.manifest.working == project.working else {
            throw LabError.invalid("Validation package, project, frozen policy or execution differs")
        }
        guard case .sameFrame = execution.statisticsLatency else {
            throw LabError.unsupported("Delayed statistics require sequence validation; this validator measures independent same-frame scenes")
        }
        _ = try DatasetValidator(baseDirectory: dataset.baseDirectory).validate(project)
        let captured = try provenance.isCaptured(authorization: project.authorizationSource)
        let samples = dataset.samples.filter { $0.split == .acceptance }
        var measurementExecution = execution
        measurementExecution.budget.maxInFlightFrames = 1
        let colorGates = policy.thresholds.filter { $0.domain == .colorTone }
        let gate = colorGates.count == 1 && colorGates[0].metric == CalibrationQualificationValidator.metric &&
            colorGates[0].unit == CalibrationQualificationValidator.unit ? colorGates[0].maximum : nil
        var maximum = 0.0, pixels = 0
        var sampleIDs = [String](), sourceIDs = Set<String>(), targetIDs = Set<String>()
        if !samples.isEmpty {
            let workspace = try Self.workspace(package: package, execution: execution)
            measurementExecution.budget.maxResidentBytes = workspace.render
            let model = try ModelPreparer(renderer: renderer).prepare(loaded.compiled, resources: loaded.resources, execution: measurementExecution)
            let adapter = try InputAdapter(renderer: renderer, working: project.working)
            let normalizer = InputNormalizer(renderer: renderer)
            var targetExecution = measurementExecution; targetExecution.budget.maxResidentBytes = workspace.target
            for (index, sample) in samples.enumerated() {
                try Task.checkCancellation()
                let result = try await measure(sample, index: index, dataset: dataset, package: package, loaded: loaded,
                    model: model, adapter: adapter, normalizer: normalizer, targetExecution: targetExecution, fileBudget: workspace.file)
                maximum = max(maximum, result.maximum); pixels += result.pixels
                sampleIDs.append(sample.id); sourceIDs.insert(result.sourceID); targetIDs.insert(result.targetID)
            }
        }
        let color: ModelDomainValidation
        let evidence: ModelDomainValidation.Evidence = captured ? .capturedTarget : .development
        if pixels == 0 {
            color = .init(domain: .colorTone, status: .insufficient, sampleIDs: sampleIDs,
                reasons: [samples.isEmpty ? "No independent acceptance samples" : "No comparable pixels remain after alignment and exclusions"])
        } else if let gate {
            color = .init(domain: .colorTone, status: maximum <= gate ? .passed : .failed, evidence: evidence,
                measurements: [CalibrationQualificationValidator.metric: maximum, "comparedPixelCount": Double(pixels)], sampleIDs: sampleIDs,
                reasons: maximum <= gate ? (captured ? [] : ["Development files do not confer measured target coverage"]) : ["Maximum encoded RGB residual exceeds the frozen acceptance threshold"])
        } else {
            color = .init(domain: .colorTone, status: .insufficient, evidence: evidence,
                measurements: [CalibrationQualificationValidator.metric: maximum, "comparedPixelCount": Double(pixels)], sampleIDs: sampleIDs,
                reasons: ["No single supported encoded RGB maximum-error threshold was frozen for color/tone"])
        }
        let domains = ValidationDomain.allCases.map { domain in
            domain == .colorTone ? color : ModelDomainValidation(domain: domain, status: .insufficient,
                reasons: ["No independent \(domain.rawValue) measurement is implemented by this color validator"])
        }
        return try .init(version: 1, packageDigest: package.digest(), modelDigest: package.manifest.modelDigest,
            projectDigest: dataset.report.projectDigest, policyDigest: Digest.data(JSON.encode(policy)), execution: execution,
            measurementExecution: measurementExecution, source: project.source, targetSource: targetSource,
            targetRecipeDigest: targetRecipe.digest(),
            algorithmVersions: ["validator": Self.algorithmVersion, "features": FrameFeatureExtractor.algorithmVersion, "noiseSeed": "42"],
            targetDecodingDigest: targetIDs.isEmpty ? nil : Digest.data(JSON.encode(targetIDs.sorted())),
            effectiveSourceIDs: sourceIDs.sorted(), domains: domains)
    }
    private struct FrameMeasurement {
        let maximum: Double
        let pixels: Int
        let sourceID: String, targetID: String
    }
    private func measure(_ sample: CalibrationSample, index: Int, dataset: CalibrationDataset, package: StyleModelPackage,
                         loaded: LoadedStyleModelPackage, model: PreparedStyleModel, adapter: InputAdapter,
                         normalizer: InputNormalizer, targetExecution: ExecutionProfile, fileBudget: Int) async throws -> FrameMeasurement {
        let reservation = try model.reserveFrame(); defer { reservation.cancel() }
        let inputBytes = try CalibrationReferenceLoader.checkedBytes(sample.input, baseDirectory: dataset.baseDirectory, maximumBytes: fileBudget)
        let targetBytes = try CalibrationReferenceLoader.checkedBytes(sample.target, baseDirectory: dataset.baseDirectory, maximumBytes: fileBudget)
        let input = try await adapter.prepare(Self.source(inputBytes, descriptor: package.manifest.source, recipe: package.manifest.recipe),
            descriptor: package.manifest.source, recipe: package.manifest.recipe, execution: reservation.execution)
        let prepared = try await normalizer.normalize(input, calibration: package.manifest.calibration, resources: loaded.inputResources)
        let target = try await adapter.prepare(Self.source(targetBytes, descriptor: targetSource, recipe: targetRecipe),
            descriptor: targetSource, recipe: targetRecipe, execution: targetExecution)
        _ = try Self.conditions(declared: sample.sourceConditions, observed: input.captureConditions)
        let targetConditions = try Self.conditions(declared: sample.targetConditions, observed: target.captureConditions)
        let stamp = FrameStamp(streamID: "acceptance:" + sample.id, generation: 0,
            index: sample.timing?.frameIndex ?? UInt64(index), presentationTime: sample.timing?.presentationTime ?? Double(index),
            duration: sample.timing?.duration ?? 1)
        // Source observations are exactly the runtime B2 facts. Manifest declarations
        // can reject contradictions, but cannot supply facts missing from live input.
        let observations = try await renderer.observe(prepared, stamp: stamp, requirements: model.compiled.definition.observations)
        let automatic = try StyleModelEvaluator.evaluate(model.compiled, context: .init(evaluationStamp: stamp, observations: observations, targetConditions: targetConditions))
        let resolved = try EditResolver.resolve(.init(), automatic: automatic, model: model.compiled)
        let plan = try RenderPlanner().plan(resolved, input: prepared, model: model, stamp: stamp, seed: 42, reservation: reservation)
        let output = try await renderer.renderTiled(prepared, plan: plan)
        let measured = try compare(output.image, width: output.width, height: output.height, target: target, alignment: sample.alignment)
        return .init(maximum: measured.maximum, pixels: measured.pixels, sourceID: input.sourceID, targetID: target.sourceID)
    }
    private static func source(_ bytes: Data, descriptor: SourceDescriptor, recipe: InputRecipe) throws -> SourceImage {
        if descriptor.path == .raw || descriptor.path == .proRAW { return .rawData(bytes) }
        guard descriptor.path == .processedPhoto, let rendition = recipe.decodedRendition else {
            throw LabError.unsupported("Validation file loader requires processed-photo or RAW input; video requires a host frame loader")
        }
        guard let image = CIImage(data: bytes, options: [.applyOrientationProperty: false, .expandToHDR: rendition == .systemReconstructed]) else {
            throw LabError.io("Cannot decode acceptance image")
        }
        return .image(image)
    }
    private static func conditions(declared: CaptureConditions, observed: CaptureConditions) throws -> CaptureConditions {
        try declared.validate(); try observed.validate()
        var merged = observed
        for axis in ConditionAxis.allCases {
            if let a = declared[axis], let b = observed[axis], abs(a - b) > max(1, abs(b)) * 1e-6 {
                throw LabError.measurement("Acceptance capture metadata contradicts frozen conditions")
            }
            if merged[axis] == nil { merged[axis] = declared[axis] }
        }
        return merged
    }
    private func compare(_ output: CIImage, width: Int, height: Int, target: NormalizedInput,
                         alignment: SampleAlignment) throws -> (maximum: Double, pixels: Int) {
        let t = alignment.inputToTarget, w = Double(width), h = Double(height)
        let tw = Double(target.width), th = Double(target.height)
        let transform = CGAffineTransform(a: t[0]*tw/w, b: t[1]*th/w, c: t[2]*tw/h, d: t[3]*th/h, tx: t[4]*tw, ty: t[5]*th)
        let aligned = target.image.transformed(by: transform.inverted())
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        var maximum = 0.0, pixels = 0
        // Read every comparable output pixel. Fixed tiles bound CPU storage; no scene reduction.
        for y in stride(from: 0, to: height, by: 128) { for x in stride(from: 0, to: width, by: 128) {
            try Task.checkCancellation()
            let cw = min(128, width-x), ch = min(128, height-y), bounds = CGRect(x: x, y: y, width: cw, height: ch)
            var a = [Float](repeating: 0, count: cw*ch*4), b = a
            a.withUnsafeMutableBytes { context.render(output, toBitmap: $0.baseAddress!, rowBytes: cw*16, bounds: bounds, format: .RGBAf, colorSpace: space) }
            b.withUnsafeMutableBytes { context.render(aligned, toBitmap: $0.baseAddress!, rowBytes: cw*16, bounds: bounds, format: .RGBAf, colorSpace: space) }
            for row in 0..<ch { for column in 0..<cw {
                // Core Image bitmap storage is top-first within this tile.
                let px = (Double(x+column)+0.5)/w, py = (Double(y+ch-row)-0.5)/h
                let tx = t[0]*px+t[2]*py+t[4], ty = t[1]*px+t[3]*py+t[5]
                guard (0...1).contains(tx), (0...1).contains(ty),
                      !alignment.exclusions.contains(where: { tx >= $0.x && tx < $0.x+$0.width && ty >= $0.y && ty < $0.y+$0.height }) else { continue }
                let i = (row*cw+column)*4
                for channel in 0..<3 {
                    let source = Double(a[i+channel]), reference = Double(b[i+channel])
                    guard source.isFinite, reference.isFinite else { throw LabError.measurement("Nonfinite acceptance pixels") }
                    maximum = max(maximum, abs(source-reference))
                }
                pixels += 1
            } }
        } }
        return (maximum, pixels)
    }
    private static func workspace(package: StyleModelPackage, execution: ExecutionProfile) throws -> (render: Int, target: Int, file: Int) {
        // Package bytes, two 128x128 RGBAf readbacks and bounded overhead stay outside
        // the rendering allowance. Platform decoder internals are not process-wide accounting.
        let packageBytes = package.modelJSON.count + package.resources.values.reduce(0) { $0+$1.count } + package.inputResources.values.reduce(0) { $0+$1.count }
        let total = execution.budget.maxResidentBytes
        guard packageBytes < total, total-packageBytes > 1_048_576 else { throw LabError.invalid("Acceptance package/readback exceeds memory budget") }
        let remaining = total-packageBytes-1_048_576
        guard remaining/8 >= 4096 else { throw LabError.invalid("Insufficient acceptance decoding workspace") }
        return (remaining/2, remaining/4, remaining/8)
    }
}
