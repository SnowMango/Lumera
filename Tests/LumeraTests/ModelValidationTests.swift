import XCTest
import CoreImage
import ImagingCore
import ImageRendering
@testable import ImageAnalysis

final class ModelValidationTests: XCTestCase {
    var execution: ExecutionProfile { .init(width: 4, height: 4, budget: .init(maxInFlightFrames: 2, maxResidentBytes: 64 * 1024 * 1024)) }
    var source: SourceDescriptor { var s = SourceDescriptor(id: "source", path: .processedPhoto); s.recipeID = "source"; return s }
    var target: SourceDescriptor { var s = SourceDescriptor(id: "target", path: .processedPhoto); s.recipeID = "target"; return s }
    func recipe(_ id: String) -> InputRecipe { .init(id: id, backend: "coreImage", version: "1", decodedRendition: .baseImage) }
    var policy: ValidationPolicy { .init(thresholds: [.init(domain: .colorTone, metric: CalibrationQualificationValidator.metric, unit: CalibrationQualificationValidator.unit, maximum: 0.005)]) }
    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    func file(_ name: String, pixels: [Float], directory: URL) throws -> CalibrationFile {
        let bytes = try ImageCodec.encodeReference(ImageFrame(width: 4, height: 4, pixels: pixels))
        try bytes.write(to: directory.appendingPathComponent(name))
        return .init(path: name, sha256: Digest.data(bytes), byteCount: bytes.count)
    }
    func project(samples: [CalibrationSample], policy: ValidationPolicy? = nil) -> CalibrationProject {
        .init(id: "synthetic-validation", target: .init(id: "target", name: "SDR"), source: source,
            inputRecipe: recipe("source"), working: .init(referenceRenditionID: "fixture"), samples: samples,
            validationPolicy: policy ?? self.policy, authorizationSource: "synthetic development fixture")
    }
    func sample(directory: URL, aligned: Bool = false) throws -> CalibrationSample {
        var a = [Float](), b = [Float]()
        for _ in 0..<4 { for x in 0..<4 {
            let value = Float(x + 1) / 5
            a += [value,value,value,1]
            let target = aligned ? (x < 2 ? Float(1) : Float(4-x)/5) : value
            b += [target,target,target,1]
        } }
        return try .init(id: "acceptance", input: file("input.png", pixels: a, directory: directory), target: file("target.png", pixels: b, directory: directory), sceneID: "acceptance-scene", split: .acceptance,
            alignment: aligned ? .init(inputToTarget: [-1,0,0,1,1,0], exclusions: [.init(x: 0, y: 0, width: 0.5, height: 1, reason: "Synthetic occlusion")]) : .init())
    }
    func testWholeScenePixelsAndOnlyAcceptanceAreMeasured() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let acceptance = try sample(directory: dir)
        let junk = Data("not a decoded training image".utf8); try junk.write(to: dir.appendingPathComponent("training.bin"))
        let train = CalibrationFile(path: "training.bin", sha256: Digest.data(junk), byteCount: junk.count)
        let p = project(samples: [.init(id: "train", input: train, target: train, sceneID: "train-scene", split: .train), acceptance])
        let dataset = try DatasetValidator(baseDirectory: dir).validate(p), renderer = try LumeraRenderer()
        let package = try ModelBuilder(renderer: renderer, execution: execution).build(p, model: .init(identity: p.target), resources: .init())
        let report = try await ModelValidator(renderer: renderer, targetSource: target, targetRecipe: recipe("target")).validate(package, dataset: dataset, policy: policy, execution: execution)
        let color = try XCTUnwrap(report.domains.first { $0.domain == .colorTone })
        XCTAssertEqual(color.status, .passed)
        XCTAssertEqual(color.sampleIDs, ["acceptance"])
        XCTAssertLessThan(try XCTUnwrap(color.measurements[CalibrationQualificationValidator.metric]), 0.005)
        XCTAssertTrue(report.measuredDomains.isEmpty)
        XCTAssertEqual(report.domains.filter { $0.domain != .colorTone }.map(\.status), Array(repeating: .insufficient, count: 5))
        XCTAssertNotNil(report.targetDecodingDigest); XCTAssertEqual(report.effectiveSourceIDs.count, 1)
        XCTAssertLessThan(report.measurementExecution.budget.maxResidentBytes, execution.budget.maxResidentBytes)
        XCTAssertEqual(report.measurementExecution.budget.maxInFlightFrames, 1)
        try report.validateBinding(package: package, dataset: dataset, policy: policy, execution: execution, targetSource: target, targetRecipe: recipe("target"))
        var wrongPrecision = execution; wrongPrecision.precision = .float32
        XCTAssertThrowsError(try report.validateBinding(package: package, dataset: dataset, policy: policy, execution: wrongPrecision, targetSource: target, targetRecipe: recipe("target")))
        var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSON.encode(report)) as? [String: Any])
        var actual = try XCTUnwrap(encoded["measurementExecution"] as? [String: Any])
        actual["precision"] = "float32"; encoded["measurementExecution"] = actual
        let changedMeasurement = try JSONDecoder().decode(ModelValidationReport.self, from: JSONSerialization.data(withJSONObject: encoded))
        XCTAssertThrowsError(try changedMeasurement.validateBinding(package: package, dataset: dataset, policy: policy, execution: execution, targetSource: target, targetRecipe: recipe("target")))
        var changedTarget = target; changedTarget.id = "another-target"
        XCTAssertThrowsError(try report.validateBinding(package: package, dataset: dataset, policy: policy, execution: execution, targetSource: changedTarget, targetRecipe: recipe("target")))
        var changedRecipe = recipe("target"); changedRecipe.version = "other-decoding-version"
        XCTAssertThrowsError(try report.validateBinding(package: package, dataset: dataset, policy: policy, execution: execution, targetSource: target, targetRecipe: changedRecipe))
        var wrongSource = try XCTUnwrap(encoded["source"] as? [String: Any]); wrongSource["path"] = "raw"
        encoded["source"] = wrongSource; actual["precision"] = "float16"; encoded["measurementExecution"] = actual
        let changedSource = try JSONDecoder().decode(ModelValidationReport.self, from: JSONSerialization.data(withJSONObject: encoded))
        XCTAssertThrowsError(try changedSource.validateBinding(package: package, dataset: dataset, policy: policy, execution: execution, targetSource: target, targetRecipe: recipe("target")))
    }
    func testAlignmentAndExclusionsUseFullOutputCoordinates() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = project(samples: [try sample(directory: dir, aligned: true)])
        let dataset = try DatasetValidator(baseDirectory: dir).validate(p), renderer = try LumeraRenderer()
        let package = try ModelBuilder(renderer: renderer, execution: execution).build(p, model: .init(identity: p.target), resources: .init())
        let report = try await ModelValidator(renderer: renderer, targetSource: target, targetRecipe: recipe("target")).validate(package, dataset: dataset, policy: policy, execution: execution)
        XCTAssertEqual(report.domains.first { $0.domain == .colorTone }?.status, .passed)
    }
    func testActualEffectFailsFrozenColorGateWithoutTuning() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = project(samples: [try sample(directory: dir)])
        let dataset = try DatasetValidator(baseDirectory: dir).validate(p), renderer = try LumeraRenderer()
        var model = StyleModel(identity: p.target); model.appearance.parameters.color.exposureEV = 1
        let package = try ModelBuilder(renderer: renderer, execution: execution).build(p, model: model, resources: .init())
        let before = try package.digest()
        let report = try await ModelValidator(renderer: renderer, targetSource: target, targetRecipe: recipe("target")).validate(package, dataset: dataset, policy: policy, execution: execution)
        let color = try XCTUnwrap(report.domains.first { $0.domain == .colorTone })
        XCTAssertEqual(color.status, .failed)
        XCTAssertGreaterThan(try XCTUnwrap(color.measurements[CalibrationQualificationValidator.metric]), 0.1)
        XCTAssertEqual(try package.digest(), before)
    }
    func testNoAcceptanceAndMissingThresholdRemainInsufficient() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let renderer = try LumeraRenderer(), validator = try ModelValidator(renderer: renderer, targetSource: target, targetRecipe: recipe("target"))
        let empty = project(samples: [])
        let package = try ModelBuilder(renderer: renderer, execution: execution).build(empty, model: .init(identity: empty.target), resources: .init())
        let report = try await validator.validate(package, dataset: DatasetValidator(baseDirectory: dir).validate(empty), policy: policy, execution: execution)
        XCTAssertTrue(report.domains.allSatisfy { $0.status == .insufficient })
        let noGate = project(samples: [try sample(directory: dir)], policy: .init())
        let ungated = try ModelBuilder(renderer: renderer, execution: execution).build(noGate, model: .init(identity: noGate.target), resources: .init())
        let ungatedReport = try await validator.validate(ungated, dataset: DatasetValidator(baseDirectory: dir).validate(noGate), policy: noGate.validationPolicy, execution: execution)
        XCTAssertEqual(ungatedReport.domains.first { $0.domain == .colorTone }?.status, .insufficient)
    }
    func testTamperedBytesPrecisionPolicyAndProvenanceReject() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = project(samples: [try sample(directory: dir)]), renderer = try LumeraRenderer()
        let dataset = try DatasetValidator(baseDirectory: dir).validate(p)
        let package = try ModelBuilder(renderer: renderer, execution: execution).build(p, model: .init(identity: p.target), resources: .init())
        let validator = try ModelValidator(renderer: renderer, targetSource: target, targetRecipe: recipe("target"))
        var high = execution; high.precision = .float32
        do { _ = try await validator.validate(package, dataset: dataset, policy: policy, execution: high); XCTFail("Cross-precision validation accepted") } catch { }
        do { _ = try await validator.validate(package, dataset: dataset, policy: .init(), execution: execution); XCTFail("Changed frozen policy accepted") } catch { }
        let wrongProvenance = try ModelValidator(renderer: renderer, targetSource: target, targetRecipe: recipe("target"), provenance: .captured(authorizationReference: "other owner"))
        do { _ = try await wrongProvenance.validate(package, dataset: dataset, policy: policy, execution: execution); XCTFail("Mismatched capture provenance accepted") } catch { }
        try Data("changed".utf8).write(to: dir.appendingPathComponent("target.png"))
        do { _ = try await validator.validate(package, dataset: dataset, policy: policy, execution: execution); XCTFail("Changed acceptance bytes accepted") } catch { }
    }
    func testVerticalExclusionUsesImageCoordinates() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = (0..<16).flatMap { _ -> [Float] in [0.5,0.5,0.5,1] }
        let b = (0..<16).flatMap { i -> [Float] in let v: Float = i < 8 ? 1 : 0.5; return [v,v,v,1] }
        let s = try CalibrationSample(id: "top-occlusion", input: file("input.png", pixels: a, directory: dir), target: file("target.png", pixels: b, directory: dir), sceneID: "vertical", split: .acceptance,
            alignment: .init(exclusions: [.init(x: 0, y: 0.5, width: 1, height: 0.5, reason: "Upper target half is occluded")]))
        let p = project(samples: [s]), renderer = try LumeraRenderer()
        let package = try ModelBuilder(renderer: renderer, execution: execution).build(p, model: .init(identity: p.target), resources: .init())
        let report = try await ModelValidator(renderer: renderer, targetSource: target, targetRecipe: recipe("target")).validate(package, dataset: DatasetValidator(baseDirectory: dir).validate(p), policy: policy, execution: execution)
        XCTAssertEqual(report.domains.first { $0.domain == .colorTone }?.status, .passed)
    }
    func testDelayedStatisticsAndSmallWorkspaceCannotClaimValidation() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = project(samples: [try sample(directory: dir)]), renderer = try LumeraRenderer()
        let dataset = try DatasetValidator(baseDirectory: dir).validate(p)
        let validator = try ModelValidator(renderer: renderer, targetSource: target, targetRecipe: recipe("target"))
        var delayed = execution; delayed.statisticsLatency = .delayed(maxFrames: 1, maxSeconds: 1)
        let delayedPackage = try ModelBuilder(renderer: renderer, execution: delayed).build(p, model: .init(identity: p.target), resources: .init())
        do { _ = try await validator.validate(delayedPackage, dataset: dataset, policy: policy, execution: delayed); XCTFail("Delayed statistics silently became same-frame validation") } catch { }
        var tight = execution; tight.budget.maxResidentBytes = 1_048_576
        let tightPackage = try ModelBuilder(renderer: renderer, execution: tight).build(p, model: .init(identity: p.target), resources: .init())
        do { _ = try await validator.validate(tightPackage, dataset: dataset, policy: policy, execution: tight); XCTFail("Readback/file workspace escaped the budget") } catch { }
    }

    func testFrozenInputCalibrationIsAppliedOnceBeforeModel() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = project(samples: [try sample(directory: dir)]), renderer = try LumeraRenderer()
        let dataset = try DatasetValidator(baseDirectory: dir).validate(p)
        let effective = EffectiveInputRecipe(declared: recipe("source"), backendVersion: ProcessInfo.processInfo.operatingSystemVersionString)
        var calibration = try InputCalibrationSolver.identity(source: source, effectiveRecipe: effective, reference: p.working)
        calibration.correction.matrix.values = [0.5,0,0,0,0.5,0,0,0,0.5]
        var model = StyleModel(identity: p.target); model.appearance.parameters.color.exposureEV = 1
        let package = try ModelBuilder(renderer: renderer, execution: execution).build(p, model: model, resources: .init(), calibration: calibration)
        let report = try await ModelValidator(renderer: renderer, targetSource: target, targetRecipe: recipe("target")).validate(package, dataset: dataset, policy: policy, execution: execution)
        XCTAssertEqual(report.domains.first { $0.domain == .colorTone }?.status, .passed)
    }

    func testMissingRuntimeISOUsesFallbackWithoutManifestInjection() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let original = try sample(directory: dir)
        var declared = CaptureConditions(); declared.iso = 400
        let inputSample = CalibrationSample(id: original.id, input: original.input, target: original.target,
            sceneID: original.sceneID, split: .acceptance, sourceConditions: declared)
        let p = project(samples: [inputSample]), renderer = try LumeraRenderer()
        var model = StyleModel(identity: p.target); model.observations.sourceConditions = [.iso]
        model.responses = [.init(target: "color.exposureEV", expression: .singleAxis(axis: .source(.iso),
            nodes: [.init(100, .scalar(0)), .init(400, .scalar(1))], boundary: .clamp), missing: .constant(.scalar(0)))]
        let normalized = try await InputAdapter(renderer: renderer, working: p.working).prepare(
            .image(try XCTUnwrap(CIImage(contentsOf: dir.appendingPathComponent(original.input.path)))),
            descriptor: source, recipe: recipe("source"), execution: execution)
        XCTAssertNil(normalized.captureConditions.iso)
        let compiled = try StyleModelCompiler.compile(model)
        let input = try await InputNormalizer(renderer: renderer).normalize(normalized, calibration: nil, resources: .init())
        let stamp = FrameStamp(streamID: "live", generation: 0, index: 0, presentationTime: 0, duration: 1)
        let observed = try await renderer.observe(input, stamp: stamp, requirements: model.observations)
        XCTAssertEqual(try StyleModelEvaluator.evaluate(compiled, context: .init(evaluationStamp: stamp, observations: observed)).parameters.color.exposureEV, 0)
        let package = try ModelBuilder(renderer: renderer, execution: execution).build(p, model: model, resources: .init())
        let report = try await ModelValidator(renderer: renderer, targetSource: target, targetRecipe: recipe("target")).validate(package,
            dataset: DatasetValidator(baseDirectory: dir).validate(p), policy: policy, execution: execution)
        XCTAssertEqual(report.domains.first { $0.domain == .colorTone }?.status, .passed)
    }
    func testEDRRequiresAnExplicitUnsupportedValidationResult() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let base = project(samples: []), checked = try DatasetValidator(baseDirectory: dir).validate(base)
        var working = base.working; working.dynamicRange = .edr
        let hdr = CalibrationProject(id: base.id, target: base.target, source: source, inputRecipe: recipe("source"),
            working: working, samples: [], validationPolicy: policy)
        // Construct the metadata snapshot directly to exercise the validator's own range boundary.
        let check = CalibrationCheckReport(schemaVersion: 1, projectID: hdr.id, projectDigest: Digest.data(try JSON.encode(hdr)),
            recipeDigest: checked.report.recipeDigest, workingDigest: try working.digest(), status: .incomplete,
            sampleCounts: checked.report.sampleCounts, missingInformation: [], baselines: checked.report.baselines)
        let dataset = CalibrationDataset(project: hdr, baseDirectory: dir, report: check)
        var hdrExecution = execution; hdrExecution.dynamicRange = .edr
        let renderer = try LumeraRenderer()
        var model = StyleModel(identity: hdr.target); model.compatibility.dynamicRanges = [.edr]
        let package = try ModelBuilder(renderer: renderer, execution: hdrExecution).build(hdr, model: model, resources: .init())
        do {
            _ = try await ModelValidator(renderer: renderer, targetSource: target, targetRecipe: recipe("target")).validate(package, dataset: dataset, policy: policy, execution: hdrExecution)
            XCTFail("EDR entered the SDR metric")
        } catch LabError.unsupported { } catch { XCTFail("Validator did not explicitly reject unsupported EDR: \(error)") }
    }

}
