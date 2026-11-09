import Foundation
import CoreImage
import ImagingCore
import ImageRendering

/// 调用方声明的来源类别。默认使用开发证据，资格还需独立测量。
public enum CalibrationEvidenceProvenance: Sendable {
    case development
    case captured(authorizationReference: String)
    func isCaptured(authorization: String?) throws -> Bool {
        switch self {
        case .development: return false
        case .captured(let reference):
            guard !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, authorization == reference else {
                throw LabError.measurement("Captured evidence must match the project's authorization source")
            }
            return true
        }
    }
}

/// 通过运行时共用的输入准备链路读取独立工作参考。调用方提供拍摄来源与参考专用对齐，不解码目标外观图像。
public final class CalibrationReferenceLoader: InputCalibrationPairLoading {
    private let adapter: InputAdapter
    private let normalizer: InputNormalizer
    private let context: CIContext
    private let execution: ExecutionProfile
    private let working: WorkingImageContract
    private let referenceSource: SourceDescriptor
    private let referenceRecipe: InputRecipe
    private let referenceAlignments: [String: SampleAlignment]
    private let resources: ModelResourceSet
    private let provenance: CalibrationEvidenceProvenance
    public init(renderer: LumeraRenderer, execution: ExecutionProfile, working: WorkingImageContract,
                referenceSource: SourceDescriptor, referenceRecipe: InputRecipe,
                referenceAlignments: [String: SampleAlignment], resources: ModelResourceSet, provenance: CalibrationEvidenceProvenance = .development) throws {
        try execution.validate(); try working.validate(); try referenceSource.validate(); try referenceRecipe.validate()
        guard working.dynamicRange == .sdr, execution.dynamicRange == .sdr,
              referenceSource.recipeID == referenceRecipe.id else { throw LabError.invalid("Explicit SDR reference source/recipe required") }
        self.adapter = try InputAdapter(renderer: renderer, working: working)
        self.normalizer = InputNormalizer(renderer: renderer)
        self.context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])
        self.execution = execution; self.working = working; self.referenceSource = referenceSource
        self.referenceRecipe = referenceRecipe; self.referenceAlignments = referenceAlignments; self.resources = resources; self.provenance = provenance
    }
    /// 在字节预算内读取原始文件并复核冻结的文件身份。
    public static func checkedBytes(_ file: CalibrationFile, baseDirectory: URL, maximumBytes: Int = Int.max) throws -> Data {
        let url = file.path.hasPrefix("/") ? URL(fileURLWithPath: file.path) : baseDirectory.appendingPathComponent(file.path)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)
        guard file.byteCount > 0, file.byteCount <= maximumBytes,
              (attributes[.size] as? NSNumber)?.intValue == file.byteCount else { throw LabError.measurement("Calibration file size changed or exceeds budget") }
        let data = try Data(contentsOf: url)
        guard data.count == file.byteCount, Digest.data(data) == file.sha256 else { throw LabError.measurement("Calibration file bytes changed: \(file.path)") }
        return data
    }
    /// 为文件缓冲、并存图像、GPU 工作区、分块回读及保留的数值样本预留内存。
    /// 预算估算不涵盖系统解码器的内部驻留内存。
    static func workspaceBudget(total: Int, maxSamples: Int) throws -> Int {
        let (sampleBytes, overflow) = maxSamples.multipliedReportingOverflow(by: 256)
        guard maxSamples > 0, !overflow, total > 1_048_576,
              sampleBytes < total - 1_048_576 else { throw LabError.invalid("Calibration sample/readback budget exceeds available memory") }
        let budget = (total - 1_048_576 - sampleBytes) / 4
        guard budget >= 4096 else { throw LabError.invalid("Insufficient calibration workspace") }
        return budget
    }
    /// 项目与解码元数据同时给出的拍摄条件必须一致。缺失观测保留为空。
    static func validateConditionAgreement(manifest:CaptureConditions,observed:CaptureConditions) throws {
        try manifest.validate();try observed.validate()
        for axis in ConditionAxis.allCases {
            if let declared=manifest[axis],let actual=observed[axis] {
                guard abs(declared-actual)<=max(1,abs(actual))*1e-6 else { throw LabError.measurement("Capture facts disagree with normalized source metadata") }
            }
        }
    }
    /// 只测量和声明指定的条件轴。
    static func measuredConditions(manifest: CaptureConditions, observed: CaptureConditions, axes: [ConditionAxis]) throws -> CaptureConditions {
        try validateConditionAgreement(manifest:manifest,observed:observed)
        guard !axes.isEmpty, Set(axes).count == axes.count else { throw LabError.measurement("Input qualification needs explicit unique condition axes") }
        var result = CaptureConditions()
        for axis in ConditionAxis.allCases {
            guard axes.contains(axis) else { continue }
            guard let value = observed[axis] ?? manifest[axis] else { throw LabError.measurement("Missing declared capture axis prevents input qualification") }
            result[axis] = value
        }
        return result
    }
    public static func referenceFile(_ sample: CalibrationSample) throws -> CalibrationFile {
        guard let reference = sample.reference else { throw LabError.measurement("Independent calibration reference missing: \(sample.id); target look is not a reference") }
        return reference
    }
    /// 按指定集合提取输入与工作参考颜色对，记录解码配方、参考身份及声明条件轴的覆盖。
    public func load(_ dataset: CalibrationDataset, split: CalibrationSplit, calibration: InputCalibration?, maxSamples: Int) async throws -> LoadedInputCalibrationPairs {
        guard dataset.project.working == working, let recipe = dataset.project.inputRecipe else { throw LabError.invalid("Dataset input recipe/reference mismatch") }
        let captured = try provenance.isCaptured(authorization: dataset.project.authorizationSource)
        let axes = dataset.project.inputQualificationAxes
        if captured && split == .acceptance {
            guard let axes, !axes.isEmpty, Set(axes).count == axes.count else { throw LabError.measurement("Input qualification axes were not frozen in the project") }
        }
        let workspace = try Self.workspaceBudget(total: execution.budget.maxResidentBytes, maxSamples: maxSamples)
        var preparationExecution = execution
        preparationExecution.budget.maxResidentBytes = workspace
        var verifiedConditions = [CaptureConditions]()
        let samples = dataset.samples.filter { $0.split == split }
        guard !samples.isEmpty, maxSamples >= samples.count else { throw LabError.measurement("Missing split or insufficient sample budget") }
        var pairs = [InputCalibrationPair](), fileDigests = [String](), effective: EffectiveInputRecipe?, referenceIdentity: String?
        let each = maxSamples / samples.count
        for sample in samples {
            try Task.checkCancellation()
            let reference = try Self.referenceFile(sample)
            guard let alignment = referenceAlignments[sample.id], alignment.inputToTarget == [1,0,0,1,0,0] else {
                throw LabError.unsupported("Explicit pixel-aligned input/reference pairs are required; target alignment cannot substitute")
            }
            for exclusion in alignment.exclusions {
                try Region(x: exclusion.x, y: exclusion.y, width: exclusion.width, height: exclusion.height).validate()
                guard !exclusion.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LabError.measurement("Reference exclusion requires a reason") }
            }
            let inputBytes = try Self.checkedBytes(sample.input, baseDirectory: dataset.baseDirectory, maximumBytes: workspace / 2)
            let referenceBytes = try Self.checkedBytes(reference, baseDirectory: dataset.baseDirectory, maximumBytes: workspace / 2)
            let input = try await adapter.prepare(Self.source(inputBytes, descriptor: dataset.project.source, recipe: recipe), descriptor: dataset.project.source, recipe: recipe, execution: preparationExecution)
            let ref = try await adapter.prepare(Self.source(referenceBytes, descriptor: referenceSource, recipe: referenceRecipe), descriptor: referenceSource, recipe: referenceRecipe, execution: preparationExecution)
            if captured && split == .acceptance {
                verifiedConditions.append(try Self.measuredConditions(manifest: sample.sourceConditions, observed: input.captureConditions, axes: axes ?? []))
            }
            guard input.width == ref.width, input.height == ref.height else { throw LabError.measurement("Reference geometry does not match input") }
            if let previous = effective, try previous.digest() != input.effectiveRecipe.digest() { throw LabError.measurement("Mixed effective input recipes require separate calibrations") }
            effective = input.effectiveRecipe
            struct ReferenceIdentity: Encodable { let source: SourceDescriptor; let recipe: String; let working: String }
            let refID = Digest.data(try JSON.encode(ReferenceIdentity(source: referenceSource, recipe: ref.effectiveRecipe.digest(), working: working.digest())))
            if let previous = referenceIdentity, previous != refID { throw LabError.measurement("Mixed reference recipes are not one frozen reference") }
            referenceIdentity = refID
            let prepared = try await normalizer.normalize(input, calibration: calibration, resources: resources)
            pairs += try readPairs(prepared.image, ref.image, width: input.width, height: input.height, budget: each, exclusions: alignment.exclusions)
            fileDigests += [sample.input.sha256, reference.sha256, Digest.data(try JSON.encode(alignment))]
        }
        guard let effective, let referenceIdentity, !pairs.isEmpty else { throw LabError.measurement("No comparable input/reference pixels") }
        let conditions = ConditionAxis.allCases.compactMap { axis -> ConditionRange? in
            let values = verifiedConditions.compactMap { $0[axis] }
            guard !verifiedConditions.isEmpty, values.count == samples.count, let low = values.min(), let high = values.max() else { return nil }
            return .init(axis: axis, bounds: .init(lower: low, upper: high))
        }
        return LoadedInputCalibrationPairs(pairs: pairs, effectiveRecipe: effective, referenceIdentity: referenceIdentity, fileDigests: fileDigests, conditionRanges: conditions, execution: execution, measuredFiles: captured)
    }
    private static func source(_ bytes: Data, descriptor: SourceDescriptor, recipe: InputRecipe) throws -> SourceImage {
        if descriptor.path == .raw || descriptor.path == .proRAW { return .rawData(bytes) }
        guard descriptor.path == .processedPhoto, let rendition = recipe.decodedRendition else { throw LabError.unsupported("File loader supports explicit processed-photo or RAW paths; YUV needs a host buffer loader") }
        guard let image = CIImage(data: bytes, options: [.applyOrientationProperty: false, .expandToHDR: rendition == .systemReconstructed]) else { throw LabError.io("Cannot decode calibration image") }
        return .image(image)
    }
    private func readPairs(_ input: CIImage, _ reference: CIImage, width: Int, height: Int, budget: Int, exclusions: [SampleExclusion]) throws -> [InputCalibrationPair] {
        let stride = max(1, Int(ceil(sqrt(Double(width) * Double(height) / Double(budget)))))
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        var result = [InputCalibrationPair]()
        // Fixed-size tiles bound CPU readback storage; both images already carry B2 normalization.
        for y in Swift.stride(from: 0, to: height, by: 128) {
            for x in Swift.stride(from: 0, to: width, by: 128) {
                try Task.checkCancellation()
                let w = min(128, width-x), h = min(128, height-y), bounds = CGRect(x:x, y:y, width:w, height:h)
                var a = [Float](repeating: 0, count: w*h*4), b = a
                a.withUnsafeMutableBytes { context.render(input, toBitmap: $0.baseAddress!, rowBytes: w*16, bounds: bounds, format: .RGBAf, colorSpace: space) }
                b.withUnsafeMutableBytes { context.render(reference, toBitmap: $0.baseAddress!, rowBytes: w*16, bounds: bounds, format: .RGBAf, colorSpace: space) }
                // CI bitmap rows run downward from this tile's maxY.
                for row in 0..<h where (y+h-1-row) % stride == 0 {
                    for col in 0..<w where (x+col) % stride == 0 {
                        let px = (Double(x+col)+0.5)/Double(width), py = (Double(y+h-row)-0.5)/Double(height)
                        if exclusions.contains(where: { px >= $0.x && px < $0.x+$0.width && py >= $0.y && py < $0.y+$0.height }) { continue }
                        let i = (row*w+col)*4
                        let pair = InputCalibrationPair(input: (0..<3).map { Double(a[i+$0]) }, reference: (0..<3).map { Double(b[i+$0]) })
                        try pair.validate(); result.append(pair)
                        if result.count == budget { return result }
                    }
                }
            }
        }
        return result
    }
}
