import XCTest
import ImagingCore
import ImageRendering
import ImageAnalysis
@testable import ImagingRuntime

final class StyleModelAcceptanceTests: XCTestCase {
    var execution: ExecutionProfile { .init(width: 4, height: 4, budget: .init(maxInFlightFrames: 2, maxResidentBytes: 32 * 1024 * 1024)) }
    func specification(device: String = "iPhone15-test-requirement", duration: Double = 60, latency: Double = 0.1, fps: Double = 30) -> DeliverySpecification {
        .init(device: device, operatingSystem: "host-declared", inputPath: .videoYUV, medium: .video(framesPerSecond: fps), execution: execution,
            maxLatencySeconds: latency, sustainedDurationSeconds: duration, maximumDroppedFrameFraction: 0.01)
    }
    func testDeliverySpecRejectsMissingBudgetOrDuration() throws {
        XCTAssertNoThrow(try specification().validate())
        XCTAssertThrowsError(try specification(device: "").validate())
        XCTAssertThrowsError(try specification(duration: 0).validate())
        XCTAssertThrowsError(try specification(latency: .nan).validate())
        XCTAssertThrowsError(try specification(fps: 0).validate())
        var invalid = execution; invalid.budget.maxResidentBytes = 0
        XCTAssertThrowsError(try DeliverySpecification(device: "test", operatingSystem: "test", inputPath: .videoYUV, medium: .video(framesPerSecond: 30), execution: invalid,
            maxLatencySeconds: 1, sustainedDurationSeconds: 1, maximumDroppedFrameFraction: 0).validate())
    }
    func testReplaySeedAndSourceFrameIdentityMatch() throws {
        let model = try StyleModelCompiler.compile(StyleModel(identity: .init(id: "synthetic", name: "test")))
        let stamp = FrameStamp(streamID: "source", generation: 7, index: UInt64(UInt32.max) + 19, presentationTime: 40, duration: 1 / 30)
        let observations = FrameObservations(stamp: stamp, sourceID: "input", calibrationID: "identity", featureDigest: model.featureDigest)
        let recipe = String(repeating: "a", count: 64)
        let record = DecisionRecord(modelDigest: model.identity, inputRecipeDigest: recipe, resourceDigest: Digest.data(try JSON.encode(model.definition.appearance.resources)),
            context: .init(evaluationStamp: stamp, observations: observations), seed: 713,
            currentInput: .init(stamp: stamp, inputID: "pixels", sourceID: "input", calibrationID: "identity", effectiveRecipeDigest: recipe, captureConditions: .init()))
        let replay = try DecisionReplay.evaluate([record], model: model)
        XCTAssertEqual(replay[0].sourceFrameIndex, stamp.index); XCTAssertEqual(replay[0].stamp, stamp)
        XCTAssertEqual(replay[0].seed, 713)
    }
    func incompleteReport() async throws -> ModelValidationReport {
        var source = SourceDescriptor(id: "input", path: .processedPhoto); source.recipeID = "ci"
        let recipe = InputRecipe(id: "ci", backend: "coreImage", version: "1", decodedRendition: .baseImage)
        let project = CalibrationProject(id: "no-samples", target: .init(id: "unverified", name: "neutral"),
            source: source, inputRecipe: recipe, working: .init(referenceRenditionID: "test"), samples: [])
        let dataset = try DatasetValidator(baseDirectory: FileManager.default.temporaryDirectory).validate(project)
        let renderer = try LumeraRenderer()
        let package = try ModelBuilder(renderer: renderer, execution: execution).build(project, model: .init(identity: project.target), resources: .init())
        return try await ModelValidator(renderer: renderer, targetSource: source, targetRecipe: recipe).validate(package, dataset: dataset, policy: project.validationPolicy, execution: execution)
    }
    func testNoRealSamplesCannotGrantCameraQualificationOrDelivery() async throws {
        let report = try await incompleteReport()
        XCTAssertTrue(report.measuredDomains.isEmpty)
        let spec = DeliverySpecification(device: "declared-device", operatingSystem: "declared-system", inputPath: .processedPhoto,
            medium: .photo, execution: execution, maxLatencySeconds: 1, sustainedDurationSeconds: 1, maximumDroppedFrameFraction: 0)
        let result = try AcceptanceRun.evaluate(specification: spec, report: report, measurements: nil)
        XCTAssertEqual(result.performance.status, .insufficient)
        XCTAssertGreaterThanOrEqual(result.missingRequirements.count, 6)
        XCTAssertThrowsError(try AcceptanceRun.evaluate(specification: specification(), report: report, measurements: nil), "A photo report cannot qualify a YUV input delivery")
    }
    func testLowLatencyDoesNotHideInsufficientFrameRate() async throws {
        let report = try await incompleteReport()
        let spec = DeliverySpecification(device: "synthetic-device", operatingSystem: "synthetic-system", inputPath: .processedPhoto,
            medium: .video(framesPerSecond: 30), execution: execution, maxLatencySeconds: 0.1,
            sustainedDurationSeconds: 60, maximumDroppedFrameFraction: 0.01)
        let cpu = Dictionary(uniqueKeysWithValues: ["input","statistics","evaluation","effects","output"].map { ($0,[0.001]) })
        let gpu = Dictionary(uniqueKeysWithValues: ["input","statistics","effects","output"].map { ($0,[0.001]) })
        let measurement = DeliveryMeasurements(device: spec.device, operatingSystem: spec.operatingSystem, durationSeconds: 60,
            deliveredFrames: 1, droppedFrames: 0, maximumInFlightFrames: 1, peakResidentBytes: 1024, endToEndP95Seconds: 0.01,
            stageCPUSeconds: cpu, stageGPUSeconds: gpu, thermalNotes: "Synthetic accounting fixture, not phone measurements")
        let result = try AcceptanceRun.evaluate(specification: spec, report: report, measurements: measurement)
        XCTAssertEqual(result.performance.status, .failed)
        XCTAssertTrue(result.performance.reasons.contains { $0.contains("frame rate") })
        XCTAssertFalse(result.missingRequirements.isEmpty)
    }

}
