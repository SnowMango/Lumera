import Foundation
import XCTest
import ImagingCore
@testable import ImageAnalysis

final class InputCalibrationQualificationTests: XCTestCase {
    private let working = WorkingImageContract(referenceRenditionID: "reference")
    private var recipe: EffectiveInputRecipe { .init(declared: .init(id: "recipe", backend: "coreImage", version: "1"), backendVersion: "test-os") }
    private func calibration(path: SourceDescriptor.Path = .processedPhoto) throws -> InputCalibration {
        try InputCalibrationSolver.identity(source: .init(id: "same-camera", path: path), effectiveRecipe: recipe, reference: working)
    }
    func testRecipeChangeInvalidatesOnlyMatchingEvidence() throws {
        let calibration = try calibration()
        XCTAssertNoThrow(try CalibrationQualificationValidator.validateIdentity(calibration, source: calibration.source, effectiveRecipe: recipe, reference: working))
        for key in [RAWSetting.Key.noiseReduction, .sharpness, .temperatureKelvin] {
            var changed = recipe; changed.settings = [.init(key: key, value: key == .temperatureKelvin ? 6000 : 0.3)]
            XCTAssertThrowsError(try CalibrationQualificationValidator.validateIdentity(calibration, source: calibration.source, effectiveRecipe: changed, reference: working))
            XCTAssertNoThrow(try CalibrationQualificationValidator.validateIdentity(calibration, source: calibration.source, effectiveRecipe: recipe, reference: working))
        }
    }
    func testQualificationAttachmentDoesNotChangeProcessingSubject() throws {
        var calibrated = try calibration()
        let subject = try calibrated.processingDigest(), full = try calibrated.digest()
        calibrated.qualifications = [.init(domain: .colorTone, evidenceDigest: String(repeating: "a", count: 64))]
        XCTAssertEqual(try calibrated.processingDigest(), subject)
        XCTAssertNotEqual(try calibrated.digest(), full)
    }
    func testFrozenPolicyCannotBeRelaxedAfterCapture() throws {
        let strict = ValidationPolicy(thresholds: [.init(domain: .colorTone, metric: CalibrationQualificationValidator.metric, unit: CalibrationQualificationValidator.unit, maximum: 0.01)])
        let relaxed = ValidationPolicy(thresholds: [.init(domain: .colorTone, metric: CalibrationQualificationValidator.metric, unit: CalibrationQualificationValidator.unit, maximum: 0.9)])
        XCTAssertThrowsError(try CalibrationQualificationValidator.colorThreshold(relaxed, frozen: strict))
        XCTAssertEqual(try CalibrationQualificationValidator.colorThreshold(strict, frozen: strict), 0.01)
    }
    func testUnknownCoverageAndContradictoryCaptureFactsReject() throws {
        XCTAssertThrowsError(try CalibrationReferenceLoader.measuredConditions(manifest: .init(), observed: .init(), axes: [.iso]))
        var complete = CaptureConditions()
        complete.iso = 100; complete.exposureDurationSeconds = 0.01; complete.exposureBiasEV = 0
        complete.whiteBalanceTemperatureKelvin = 5000; complete.whiteBalanceTintDuv = 0
        var observed = CaptureConditions(); observed.iso = 200
        XCTAssertThrowsError(try CalibrationReferenceLoader.measuredConditions(manifest: complete, observed: observed, axes: [.iso]))
        observed.iso = 100
        let scoped = try CalibrationReferenceLoader.measuredConditions(manifest: complete, observed: observed, axes: [.iso])
        XCTAssertEqual(scoped.iso, 100)
        XCTAssertNil(scoped.whiteBalanceTemperatureKelvin)
        XCTAssertThrowsError(try CalibrationReferenceLoader.measuredConditions(manifest: complete, observed: observed, axes: []))
        XCTAssertThrowsError(try CalibrationReferenceLoader.measuredConditions(manifest: complete, observed: observed, axes: [.iso, .iso]))
    }
    func testLoaderReservesConcurrentReadbackAndSampleStorage() throws {
        XCTAssertThrowsError(try CalibrationReferenceLoader.workspaceBudget(total: 1_000_000, maxSamples: 100_000))
        XCTAssertLessThan(try CalibrationReferenceLoader.workspaceBudget(total: 64_000_000, maxSamples: 1000), 64_000_000 / 3)
    }
    func testDevelopmentFilesDoNotBecomeCapturedEvidenceAutomatically() throws {
        XCTAssertFalse(try CalibrationEvidenceProvenance.development.isCaptured(authorization: "synthetic fixture"))
        XCTAssertThrowsError(try CalibrationEvidenceProvenance.captured(authorizationReference: "owner-A").isCaptured(authorization: "owner-B"))
        XCTAssertThrowsError(try CalibrationEvidenceProvenance.captured(authorizationReference: "").isCaptured(authorization: ""))
        XCTAssertTrue(try CalibrationEvidenceProvenance.captured(authorizationReference: "owner-A").isCaptured(authorization: "owner-A"))
    }
    func testChangedReferenceInvalidatesQualificationIdentity() throws {
        var calibrated = try calibration()
        calibrated.referenceDigest = String(repeating: "a", count: 64)
        XCTAssertNoThrow(try CalibrationQualificationValidator.validateIdentity(calibrated, source: calibrated.source,
                           effectiveRecipe: recipe, reference: working, referenceDigest: String(repeating: "a", count: 64)))
        XCTAssertThrowsError(try CalibrationQualificationValidator.validateIdentity(calibrated, source: calibrated.source,
                           effectiveRecipe: recipe, reference: working, referenceDigest: String(repeating: "b", count: 64)))
        calibrated.referenceDigest = "invalid"
        XCTAssertThrowsError(try calibrated.validate())
    }
    func testYUVAndHEIFNeedSeparateQualification() throws {
        let calibration = try calibration()
        var video = calibration.source; video.path = .videoYUV
        XCTAssertThrowsError(try CalibrationQualificationValidator.validateIdentity(calibration, source: video, effectiveRecipe: recipe, reference: working))
    }
    func testColorPassDoesNotGrantTextureOrTemporalQualification() throws {
        let pairs = [InputCalibrationPair(input: [0.2,0.3,0.4], reference: [0.201,0.3,0.4])]
        let result = try CalibrationQualificationValidator.measure(pairs)
        XCTAssertEqual(result.domain, .colorTone)
        XCTAssertEqual(result.maximumAbsoluteError, 0.001, accuracy: 1e-12)
        XCTAssertTrue(try calibration().qualifications.isEmpty)
    }
    func testMissingOrUnsupportedThresholdCannotPass() throws {
        XCTAssertThrowsError(try CalibrationQualificationValidator.colorThreshold(.init()))
        XCTAssertThrowsError(try CalibrationQualificationValidator.colorThreshold(.init(thresholds: [.init(domain: .texture, metric: "error", unit: "RGB", maximum: 1)])))
        XCTAssertThrowsError(try CalibrationQualificationValidator.colorThreshold(.init(thresholds: [.init(domain: .colorTone, metric: "unknown", unit: "RGB", maximum: 1)])))
    }
    func testFileBytesAreRecheckedAndReferenceCannotFallbackToTarget() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let bytes = Data("reference".utf8); try bytes.write(to: url)
        let file = CalibrationFile(path: url.path, sha256: Digest.data(bytes), byteCount: bytes.count)
        XCTAssertEqual(try CalibrationReferenceLoader.checkedBytes(file, baseDirectory: url.deletingLastPathComponent()), bytes)
        try Data("different".utf8).write(to: url)
        XCTAssertThrowsError(try CalibrationReferenceLoader.checkedBytes(file, baseDirectory: url.deletingLastPathComponent()))
        let sample = CalibrationSample(id: "a", input: file, target: file, sceneID: "s", split: .train)
        XCTAssertThrowsError(try CalibrationReferenceLoader.referenceFile(sample))
    }
}
