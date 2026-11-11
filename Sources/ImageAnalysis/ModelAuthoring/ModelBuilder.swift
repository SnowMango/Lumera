import Foundation
import ImagingCore
import ImageRendering

/// 绑定模型字节、输入与外观资源、项目身份和准备配置，并记录制作来源。
public struct ModelPackageManifest: Codable, Equatable, Sendable {
    public enum Derivation: String, Codable, Sendable { case manual, forwardFit, visualRevision }
    public var version: Int
    public var modelDigest: String
    public var modelBytesDigest: String
    public let resourceDigests: [String: String]
    public let inputResourceDigests: [String: String]
    public var projectDigest: String
    public let source: SourceDescriptor
    public let recipe: InputRecipe
    public let working: WorkingImageContract
    public let calibration: InputCalibration?
    public let preparedFor: ExecutionProfile
    public let derivation: Derivation
    public let algorithmVersion: String
    public let parentPackageDigest: String?
    public let revisionReason: String?
    public let visualRevision: ModelVisualRevision?
}
/// 可移植的模型定义、资源字节和清单。原始照片与独立验收报告单独保存。
public struct StyleModelPackage: Codable, Equatable, Sendable {
    public let modelJSON: Data
    public let resources: [String: Data]
    public let inputResources: [String: Data]
    public let manifest: ModelPackageManifest
    private struct Persisted: Encodable {
        let modelJSON: Data
        let resources: [String: Data]
        let inputResources: [String: Data]
        let manifest: ModelPackageManifest
    }
    /// Existing report bindings refer to the original package, not a migrated save.
    public func digest() throws -> String {
        Digest.data(try JSON.encode(Persisted(modelJSON: modelJSON, resources: resources, inputResources: inputResources, manifest: manifest)))
    }
    public func encode(to encoder: Encoder) throws {
        let loaded = try load()
        let bytes = try StyleModelCodec.encode(loaded.model)
        var updated = manifest
        updated.version = 2
        updated.modelDigest = try loaded.model.digest()
        updated.modelBytesDigest = Digest.data(bytes)
        try Persisted(modelJSON: bytes, resources: resources, inputResources: inputResources, manifest: updated).encode(to: encoder)
    }
    /// 校验模型及资源字节的清单绑定，返回编译后的模型与两组资源。
    public func load() throws -> LoadedStyleModelPackage {
        guard [1, 2].contains(manifest.version), !manifest.algorithmVersion.isEmpty,
              Digest.data(modelJSON) == manifest.modelBytesDigest else { throw LabError.invalid("Package model content changed") }
        guard try StyleModelCodec.persistedModelDigest(modelJSON) == manifest.modelDigest else { throw LabError.invalid("Package model semantics changed") }
        let model = try StyleModelCodec.decode(modelJSON), compiled = try StyleModelCompiler.compile(model)
        try manifest.source.validate(); try manifest.recipe.validate(); try manifest.working.validate(); try manifest.preparedFor.validate()
        guard manifest.source.recipeID == manifest.recipe.id else { throw LabError.invalid("Package source recipe mismatch") }
        if let calibration = manifest.calibration {
            try calibration.validate()
            guard calibration.source == manifest.source, calibration.working == manifest.working else { throw LabError.invalid("Package calibration/reference mismatch") }
        }
        let style = try Self.decodeResources(resources, descriptors: model.appearance.resources, digests: manifest.resourceDigests)
        let input = try Self.decodeResources(inputResources, descriptors: manifest.calibration?.resources ?? [], digests: manifest.inputResourceDigests)
        if let calibration = manifest.calibration { try InputNormalizer.validateResources(calibration, resources: input) }
        return .init(model: model, compiled: compiled, resources: style, inputResources: input)
    }
    /// Migrates a verified project/package pair. Existing reports remain bound to the old package.
    public func migrated(project: CalibrationProject) throws -> (project: CalibrationProject, package: StyleModelPackage) {
        let loaded = try load()
        guard try project.matchesDigest(manifest.projectDigest), loaded.model.identity == project.target,
              manifest.source == project.source, manifest.recipe == project.inputRecipe,
              manifest.working == project.working else { throw LabError.invalid("Migration project does not match package") }
        let newProject = try JSONDecoder().decode(CalibrationProject.self, from: JSON.encode(project))
        let bytes = try StyleModelCodec.encode(loaded.model)
        var updated = manifest
        updated.version = 2; updated.modelDigest = try loaded.model.digest()
        updated.modelBytesDigest = Digest.data(bytes)
        updated.projectDigest = Digest.data(try JSON.encode(newProject))
        let package = StyleModelPackage(modelJSON: bytes, resources: resources, inputResources: inputResources, manifest: updated)
        _ = try package.load()
        return (newProject, package)
    }
    /// 逐条核对回放记录的完整有效配方及其内容绑定。
    public func validateReplayInputs(_ records: [DecisionRecord]) throws {
        _ = try load()
        let calibrationID = try manifest.calibration?.digest() ?? InputCalibration.unqualifiedReferenceIdentity(working: manifest.working)
        for record in records {
            guard let facts = record.currentInput, let recipe = facts.effectiveRecipe,
                  recipe.declared == manifest.recipe else { throw LabError.invalid("Package replay requires matching complete effective input recipes") }
            try facts.validate()
            guard facts.effectiveRecipeDigest == record.inputRecipeDigest,
                  facts.sourceID == (try manifest.source.contentIdentity(effectiveRecipeDigest: record.inputRecipeDigest, working: manifest.working)),
                  facts.calibrationID == calibrationID,
                  manifest.calibration == nil || manifest.calibration?.recipeDigest == record.inputRecipeDigest else {
                throw LabError.invalid("Replay input contract differs from package source, recipe or calibration")
            }
        }
    }
    static func decodeResources(_ bytes: [String: Data], descriptors: [ModelResourceDescriptor], digests: [String: String]) throws -> ModelResourceSet {
        guard Set(bytes.keys) == Set(descriptors.map(\.id)), Set(digests.keys) == Set(bytes.keys) else { throw LabError.invalid("Package resource catalog mismatch") }
        var luts = [String: LUTAsset](), curves = [String: ResponseCurve]()
        for descriptor in descriptors {
            guard let data = bytes[descriptor.id], Digest.data(data) == digests[descriptor.id], Digest.data(data) == descriptor.sha256 else {
                throw LabError.invalid("Package resource bytes changed")
            }
            if descriptor.role == .toneCurve { curves[descriptor.id] = try JSONDecoder().decode(ResponseCurve.self, from: data) }
            else {
                guard let text = String(data: data, encoding: .utf8) else { throw LabError.invalid("LUT is not UTF8") }
                var asset = LUTAsset(name: descriptor.id, cubeText: text)
                asset.boundaryPolicy = descriptor.outOfRange == .linearExtrapolation ? .extrapolate : .clamp
                luts[descriptor.id] = asset
            }
        }
        return try .init(luts: luts, curves: curves)
    }
}
public struct LoadedStyleModelPackage: Sendable {
    public let model: StyleModel
    public let compiled: CompiledStyleModel
    public let resources: ModelResourceSet
    public let inputResources: ModelResourceSet
}

/// 将手动定义或拟合结果编译并按指定设备配置准备，封装为运行时模型包。
public struct ModelBuilder {
    private let renderer: LumeraRenderer
    private let execution: ExecutionProfile
    public init(renderer: LumeraRenderer, execution: ExecutionProfile) throws {
        try execution.validate(); self.renderer = renderer; self.execution = execution
    }
    /// 以显式模型和资源制作手动来源的模型包。
    public func build(_ project: CalibrationProject, model: StyleModel, resources: ModelResourceSet,
                      calibration: InputCalibration? = nil, inputResources: ModelResourceSet? = nil) throws -> StyleModelPackage {
        try assemble(project, model: model, resources: resources, calibration: calibration,
            inputResources: inputResources, derivation: .manual, algorithm: "manual-model-package-v2", parent: nil, reason: nil)
    }
    /// 核对拟合的项目和样本绑定，将模型、校准与输入及外观资源封包。
    public func build(_ project: CalibrationProject, fit: ModelFitResult, inputResources: ModelResourceSet? = nil) throws -> StyleModelPackage {
        let projectMatches = try fit.projectDigest.map { try project.matchesDigest($0) } ?? true
        guard projectMatches,
              Set(fit.consumedSampleIDs).isSubset(of: Set(project.samples.filter { $0.split != .acceptance }.map(\.id))) else {
            throw LabError.invalid("Fit consumed another project or independent acceptance samples")
        }
        return try assemble(project, model: fit.model, resources: fit.resources, calibration: fit.calibration,
            inputResources: inputResources, derivation: fit.derivation == .manual ? .manual : .forwardFit,
            algorithm: fit.algorithmVersion, parent: nil, reason: nil)
    }
    func assemble(_ project: CalibrationProject, model: StyleModel, resources: ModelResourceSet,
                  calibration: InputCalibration?, inputResources: ModelResourceSet?, derivation: ModelPackageManifest.Derivation,
                  algorithm: String, parent: String?, reason: String?, revision: ModelVisualRevision? = nil) throws -> StyleModelPackage {
        guard model.identity == project.target, let recipe = project.inputRecipe else { throw LabError.invalid("Package target or input recipe differs from project") }
        try project.source.validate(); try recipe.validate(); try project.working.validate(); try project.validationPolicy.validate()
        guard project.source.recipeID == recipe.id, model.coverage.evidenceDigests.isEmpty else {
            throw LabError.invalid("Build a new candidate without inherited measured evidence; validate the final package separately")
        }
        if let calibration {
            try calibration.validate()
            guard calibration.source == project.source, calibration.working == project.working else { throw LabError.invalid("Input calibration differs from project") }
        }
        let compiled = try StyleModelCompiler.compile(model)
        _ = try ModelPreparer(renderer: renderer).prepare(compiled, resources: resources, execution: execution)
        let modelBytes = try StyleModelCodec.encode(model)
        let values = try Self.encodeResources(resources, descriptors: model.appearance.resources)
        let inputValues = try Self.encodeResources(inputResources ?? ModelResourceSet(), descriptors: calibration?.resources ?? [])
        let manifest = ModelPackageManifest(version: 2, modelDigest: compiled.identity, modelBytesDigest: Digest.data(modelBytes),
            resourceDigests: values.mapValues(Digest.data), inputResourceDigests: inputValues.mapValues(Digest.data),
            projectDigest: Digest.data(try JSON.encode(project)), source: project.source, recipe: recipe, working: project.working,
            calibration: calibration, preparedFor: execution, derivation: derivation, algorithmVersion: algorithm,
            parentPackageDigest: parent, revisionReason: reason, visualRevision: revision)
        let package = StyleModelPackage(modelJSON: modelBytes, resources: values, inputResources: inputValues, manifest: manifest)
        _ = try package.load()
        return package
    }
    static func encodeResources(_ resources: ModelResourceSet, descriptors: [ModelResourceDescriptor]) throws -> [String: Data] {
        guard Set(resources.luts.keys).union(resources.curves.keys) == Set(descriptors.map(\.id)) else { throw LabError.invalid("Package has missing or undeclared resources") }
        var result = [String: Data]()
        for descriptor in descriptors {
            let data: Data
            if descriptor.role == .toneCurve {
                guard let curve = resources.curves[descriptor.id] else { throw LabError.invalid("Missing package curve") }
                data = try JSON.encode(curve)
            } else {
                guard let asset = resources.luts[descriptor.id] else { throw LabError.invalid("Missing package LUT") }
                data = Data(asset.cubeText.utf8)
            }
            guard Digest.data(data) == descriptor.sha256 else { throw LabError.invalid("Resource digest mismatch") }
            result[descriptor.id] = data
        }
        return result
    }
}

/// 将视觉编辑明确应用到基础外观或指定响应锚点的发布请求。
public struct ModelVisualRevision: Codable, Equatable, Sendable {
    public enum Destination: Codable, Equatable, Sendable { case base; case responseAnchor(target: String, index: Int) }
    public let destination: Destination
    public let edits: EditRequest
    public init(destination: Destination, edits: EditRequest) { self.destination = destination; self.edits = edits }
}
extension ModelBuilder {
    /// 将运行时共用的视觉映射写入指定基础外观或锚点。会话输入调整、覆盖和锁定留在会话内。
    public func revise(_ package: StyleModelPackage, project: CalibrationProject,
                       revision: ModelVisualRevision, reason: String) throws -> StyleModelPackage {
        let loaded = try package.load(), edits = revision.edits
        guard try project.matchesDigest(package.manifest.projectDigest),
              !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              edits.inputExposureEV == 0, edits.inputWhiteBalance == nil,
              edits.overrides.isEmpty, edits.locks.isEmpty, edits.strength == nil,
              !edits.visualOffsets.isEmpty else { throw LabError.invalid("Visual revision requires an explicit project, destination, reason and visual offsets only") }
        var model = loaded.model, parameters = model.appearance.parameters, weights = model.appearance.lutWeights
        var selection: Int?
        switch revision.destination {
        case .base: break
        case .responseAnchor(let target, let index):
            guard let i = model.responses.firstIndex(where: { $0.target == target }),
                  model.responses[i].expression.values.indices.contains(index) else { throw LabError.invalid("Unknown response anchor") }
            selection = i
            try ControlAccess.apply(model.responses[i].expression.values[index], target: target, parameters: &parameters, lutWeights: &weights)
        }
        let beforeParameters = parameters, beforeWeights = weights
        let automatic = AutomaticControls(parameters: parameters, lutWeights: weights, modelID: loaded.compiled.identity,
            sourceID: "authoring", calibrationID: "frozen-input", featureDigest: loaded.compiled.featureDigest)
        let resolved = try EditResolver.resolve(edits, automatic: automatic, model: loaded.compiled)
        switch revision.destination {
        case .base:
            for response in model.responses {
                guard try ControlAccess.value(target: response.target, parameters: parameters, lutWeights: weights) ==
                    ControlAccess.value(target: response.target, parameters: resolved.parameters, lutWeights: resolved.lutWeights) else {
                    throw LabError.invalid("Choose a response anchor to revise a condition-dependent control")
                }
            }
            model.appearance.parameters = resolved.parameters; model.appearance.lutWeights = resolved.lutWeights
        case .responseAnchor(let target, let index):
            let value = try ControlAccess.value(target: target, parameters: resolved.parameters, lutWeights: resolved.lutWeights)
            var check = beforeParameters, checkWeights = beforeWeights
            try ControlAccess.apply(value, target: target, parameters: &check, lutWeights: &checkWeights)
            guard check == resolved.parameters, checkWeights == resolved.lutWeights else {
                throw LabError.invalid("Anchor visual revision changes another control; revise its own destination explicitly")
            }
            let i = selection!
            switch model.responses[i].expression {
            case .constant: model.responses[i].expression = .constant(value)
            case .singleAxis(let axis, var nodes, let boundary):
                nodes[index].value = value; model.responses[i].expression = .singleAxis(axis: axis, nodes: nodes, boundary: boundary)
            case .twoAxisGrid(let xa, let ya, let x, let y, var values, let boundary):
                values[index] = value; model.responses[i].expression = .twoAxisGrid(xAxis: xa, yAxis: ya, x: x, y: y, values: values, boundary: boundary)
            }
        }
        model.coverage.evidenceDigests = []
        return try assemble(project, model: model, resources: loaded.resources, calibration: package.manifest.calibration,
            inputResources: loaded.inputResources, derivation: .visualRevision, algorithm: "visual-revision-v1",
            parent: package.digest(), reason: reason, revision: revision)
    }
}
