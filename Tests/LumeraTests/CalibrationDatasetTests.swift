import Foundation
import XCTest
import ImagingCore
@testable import ImageAnalysis

final class CalibrationDatasetTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func sample(_ id: String, scene: String? = nil, sequence: String? = nil,
                        split: CalibrationSplit = .train, alignment: SampleAlignment? = nil,
                        conditions: CaptureConditions = .init()) throws -> CalibrationSample {
        func file(_ suffix: String) throws -> CalibrationFile {
            let path = id + suffix
            let data = Data(path.utf8)
            try data.write(to: directory.appendingPathComponent(path))
            return CalibrationFile(path: path, sha256: Digest.data(data), byteCount: data.count)
        }
        return CalibrationSample(id: id, input: try file("-input"), target: try file("-target"),
                                 sceneID: scene ?? id, sequenceID: sequence, split: split,
                                 alignment: alignment ?? .init(), sourceConditions: conditions)
    }
    private func project(_ samples: [CalibrationSample], targetMode: String = "standard",
                         recipe: InputRecipe? = .init(id: "recipe", backend: "test", version: "1"),
                         policy: ValidationPolicy = .init()) -> CalibrationProject {
        var source = SourceDescriptor(id: "source", path: .processedPhoto)
        source.recipeID = "recipe"
        var target = ModelIdentity(id: "target", name: targetMode)
        target.metadata["firmware"] = "test-version"
        return CalibrationProject(id: "project", target: target, source: source, inputRecipe: recipe,
                                  working: .init(referenceRenditionID: "reference"), samples: samples,
                                  validationPolicy: policy, authorizationSource: "synthetic development test")
    }
    private func validate(_ project: CalibrationProject) throws -> CalibrationDataset {
        try DatasetValidator(baseDirectory: directory).validate(project)
    }
    func testSameSceneOrSequenceCannotCrossSplits() throws {
        for sharedSequence in [false, true] {
            let a = try sample("a", scene: sharedSequence ? "scene-a" : "same-scene", sequence: sharedSequence ? "same-sequence" : nil)
            let b = try sample("b", scene: sharedSequence ? "scene-b" : "same-scene", sequence: sharedSequence ? "same-sequence" : nil, split: .acceptance)
            XCTAssertThrowsError(try validate(project([a, b])))
        }
    }
    func testChangedBytesSameMtimeRejects() throws {
        let a = try sample("a")
        let path = directory.appendingPathComponent(a.input.path)
        let date = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path.path)[.modificationDate] as? Date)
        try Data(repeating: 120, count: a.input.byteCount).write(to: path)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path.path)
        XCTAssertThrowsError(try validate(project([a])))
    }
    func testMissingTargetModeOrInputRecipeRejects() throws {
        XCTAssertThrowsError(try validate(project([], targetMode: "  ")))
        XCTAssertThrowsError(try validate(project([], recipe: nil)))
    }
    func testNoDataReportsIncompleteNotPassed() throws {
        let dataset = try validate(project([]))
        XCTAssertEqual(dataset.report.status, .incomplete)
        XCTAssertTrue(dataset.report.missingInformation.contains("samples"))
        XCTAssertTrue(dataset.report.baselines.allSatisfy { $0.status == .insufficient })
    }
    func testMissingThresholdsCannotGrantReadiness() throws {
        let samples = try [sample("a"), sample("b", split: .tune), sample("c", split: .acceptance)]
        let dataset = try validate(project(samples))
        XCTAssertEqual(dataset.report.status, .incomplete)
        XCTAssertTrue(dataset.report.missingInformation.contains("validationPolicy.thresholds"))
    }
    func testSnapshotsPreserveAlignmentExclusionsAndConditions() throws {
        var conditions = CaptureConditions(); conditions.iso = 200
        let alignment = SampleAlignment(inputToTarget: [1, 0, 0, 1, 0.1, 0],
                                        exclusions: [.init(x: 0, y: 0, width: 0.2, height: 0.3, reason: "parallax")],
                                        notes: "normalized target coordinates")
        let original = project([try sample("a", alignment: alignment, conditions: conditions)])
        let roundTrip = try JSONDecoder().decode(CalibrationProject.self, from: JSONEncoder().encode(original))
        let dataset = try validate(roundTrip)
        XCTAssertEqual(dataset.samples[0].alignment, alignment)
        XCTAssertEqual(dataset.samples[0].sourceConditions.iso, 200)
        XCTAssertNil(dataset.samples[0].targetConditions.iso)
        XCTAssertEqual(dataset.samples[0].input.sha256, original.samples[0].input.sha256)
    }
    func testRepeatedBytesCannotCrossSplits() throws {
        let a = try sample("a")
        let b = CalibrationSample(id: "b", input: a.input, target: a.target, sceneID: "different", split: .acceptance)
        XCTAssertThrowsError(try validate(project([a, b])))
    }
    func testInvalidRegionsConditionsAndRecipeBindingReject() throws {
        let bad = SampleAlignment(exclusions: [.init(x: 0.9, y: 0, width: 0.2, height: 1, reason: "bad")])
        XCTAssertThrowsError(try validate(project([try sample("a", alignment: bad)])))
        var conditions = CaptureConditions(); conditions.iso = -1
        XCTAssertThrowsError(try validate(project([try sample("b", conditions: conditions)])))
        XCTAssertThrowsError(try validate(project([], recipe: .init(id: "wrong", backend: "test", version: "1"))))
    }
    func testValidDatasetStillDoesNotInventMeasuredBaseline() throws {
        let samples = try [sample("a"), sample("b", split: .tune), sample("c", split: .acceptance)]
        let threshold = ValidationThreshold(domain: .colorTone, metric: "encoded RGB maximum absolute error", unit: "normalized", maximum: 0.02)
        let dataset = try validate(project(samples, policy: .init(version: "test-1", thresholds: [threshold])))
        XCTAssertEqual(dataset.report.status, .readyForDevelopment)
        XCTAssertTrue(dataset.report.baselines.allSatisfy { $0.status == .insufficient && $0.value == nil })
        XCTAssertEqual(dataset.report.sampleCounts["acceptance"], 1)
    }
    func testReferencePairIsPreservedAndBytesAreValidated() throws {
        let a = try sample("a"), reference = try sample("reference").input
        let withReference = CalibrationSample(id: a.id, input: a.input, target: a.target,
                                             reference: reference, sceneID: a.sceneID, split: .train)
        let original = project([withReference])
        let decoded = try JSONDecoder().decode(CalibrationProject.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(try validate(decoded).samples[0].reference, reference)
        try Data("changed".utf8).write(to: directory.appendingPathComponent(reference.path))
        XCTAssertThrowsError(try validate(decoded))
    }
    func testUnknownFixedParameterRejects() throws {
        XCTAssertThrowsError(try FitOptions(fixedParameters: ["not.a.parameter"]).validate())
        XCTAssertNoThrow(try FitOptions(fixedParameters: ["color.matrix", "tone.curve"]).validate())
    }
    func testInvalidFitBudgetAndThresholdReject() throws {
        XCTAssertThrowsError(try FitOptions(maxIterations: 0).validate())
        XCTAssertThrowsError(try ValidationPolicy(thresholds: [.init(domain: .texture, metric: "error", unit: "normalized", maximum: -1)]).validate())
    }
}
