import XCTest
import ImagingCore
import ImageRendering
@testable import ImageAnalysis

final class ModelBuilderTests: XCTestCase {
    func project() -> CalibrationProject {
        var source = SourceDescriptor(id: "source", path: .processedPhoto); source.recipeID = "ci"
        return .init(id: "synthetic", target: .init(id: "manual", camera: "fixture", mode: "neutral"), source: source,
            inputRecipe: .init(id: "ci", backend: "coreImage", version: "1", decodedRendition: .baseImage),
            working: .init(referenceRenditionID: "reference"), samples: [])
    }
    var execution: ExecutionProfile { .init(width: 4, height: 4, budget: .init(maxInFlightFrames: 1, maxResidentBytes: 32 * 1024 * 1024)) }
    func testManualModelCanBuildAndRoundTripWithoutClaimingMeasured() throws {
        let p = project(), builder = try ModelBuilder(renderer: LumeraRenderer(), execution: execution)
        let fit = try CameraFitResult(model: .init(identity: p.target), resources: .init())
        let package = try builder.build(p, fit: fit)
        let decoded = try JSONDecoder().decode(CameraModelPackage.self, from: JSON.encode(package))
        XCTAssertEqual(package, decoded)
        XCTAssertEqual(try decoded.load().compiled.identity, try package.load().compiled.identity)
        XCTAssertEqual(decoded.manifest.derivation, .manual)
        XCTAssertTrue(try decoded.load().model.coverage.evidenceDigests.isEmpty)
        XCTAssertFalse(String(decoding: try JSON.encode(package), as: UTF8.self).contains("samples"))
    }
    func testChangedModelOrMissingResourceRejectsReload() throws {
        let p = project(), builder = try ModelBuilder(renderer: LumeraRenderer(), execution: execution)
        let package = try builder.build(p, model: .init(identity: p.target), resources: .init())
        var changed = try package.load().model; changed.appearance.parameters.color.exposureEV = 1
        let bad = CameraModelPackage(modelJSON: try CameraModelCodec.encode(changed), resources: package.resources, inputResources: package.inputResources, manifest: package.manifest)
        XCTAssertThrowsError(try bad.load())
        var missing = CameraModel(identity: p.target)
        missing.appearance.resources = [.init(id: "absent", sha256: String(repeating: "a", count: 64), dimension: 2)]
        XCTAssertThrowsError(try builder.build(p, model: missing, resources: .init()))
    }
    func testVisualRevisionUsesRuntimeMappingAndInvalidatesIdentity() throws {
        let p = project(), builder = try ModelBuilder(renderer: LumeraRenderer(), execution: execution)
        var model = CameraModel(identity: p.target)
        model.edits.visualControls = [.init(id: "exposure", unit: .ev, bounds: .init(lower: -1, upper: 1), links: [.init(target: "color.exposureEV", coefficient: 0.5)])]
        let package = try builder.build(p, model: model, resources: .init())
        var edits = EditRequest(); edits.visualOffsets = [.init(id: "exposure", value: 0.4)]
        let revised = try builder.revise(package, project: p, revision: .init(destination: .base, edits: edits), reason: "Measured preview visual adjustment")
        XCTAssertEqual(try revised.load().model.appearance.parameters.color.exposureEV, 0.2, accuracy: 1e-10)
        XCTAssertNotEqual(try revised.digest(), try package.digest())
        XCTAssertEqual(revised.manifest.parentPackageDigest, try package.digest())
        XCTAssertEqual(revised.manifest.visualRevision?.edits, edits)
        XCTAssertEqual(try package.load().model.appearance.parameters.color.exposureEV, 0)
        edits.inputExposureEV = 1
        XCTAssertThrowsError(try builder.revise(package, project: p, revision: .init(destination: .base, edits: edits), reason: "bad input edit"))
    }
    func testVisualAnchorRevisionDoesNotBakeOtherConditionsIntoBase() throws {
        let p = project(), builder = try ModelBuilder(renderer: LumeraRenderer(), execution: execution)
        var model = CameraModel(identity: p.target)
        model.observations.sourceConditions = [.iso]
        model.responses = [.init(target: "color.exposureEV", expression: .singleAxis(axis: .source(.iso), nodes: [.init(100,.scalar(0)),.init(800,.scalar(1))], boundary: .clamp))]
        model.edits.visualControls = [.init(id: "exposure", unit: .ev, bounds: .init(lower: -1, upper: 1), links: [.init(target: "color.exposureEV", coefficient: 1)])]
        let package = try builder.build(p, model: model, resources: .init())
        var edits = EditRequest(); edits.visualOffsets = [.init(id: "exposure", value: 0.2)]
        XCTAssertThrowsError(try builder.revise(package, project: p, revision: .init(destination: .base, edits: edits), reason: "ambiguous"))
        let revised = try builder.revise(package, project: p, revision: .init(destination: .responseAnchor(target: "color.exposureEV", index: 1), edits: edits), reason: "Anchor edit")
        let output = try revised.load().model
        XCTAssertEqual(output.appearance.parameters, model.appearance.parameters)
        XCTAssertEqual(output.responses[0].expression.values, [.scalar(0),.scalar(1.2)])
    }
    func testFitCannotConsumeAcceptanceSamples() throws {
        let p = project(), builder = try ModelBuilder(renderer: LumeraRenderer(), execution: execution)
        let fit = CameraFitResult(model: .init(identity: p.target), resources: try .init(), calibration: nil,
            baselineDigest: String(repeating: "a", count: 64), projectDigest: Digest.data(try JSON.encode(p)),
            consumedSampleIDs: ["acceptance-not-in-training"], measurementDigests: [], conditionDomains: [], trainResidual: 0, tuneResidual: 0,
            unresolved: [], algorithmVersion: "test", derivation: .c3ForwardFits)
        XCTAssertThrowsError(try builder.build(p, fit: fit))
    }
    func testCorrectionResourceContractIsCheckedBeforePublishing() throws {
        let p = project(), builder = try ModelBuilder(renderer: LumeraRenderer(), execution: execution)
        let asset = LUTAsset(name: "identity", cubeText: "LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n")
        var descriptor = ModelResourceDescriptor(id: "input-lut", sha256: asset.sha256, dimension: 3)
        descriptor.role = .correctionLUT
        var calibration = InputCalibration(id: "input", source: p.source, working: p.working)
        calibration.recipeDigest = String(repeating: "a", count: 64); calibration.resources = [descriptor]
        let inputResources = try ModelResourceSet(luts: [descriptor.id: asset])
        XCTAssertThrowsError(try builder.build(p, model: .init(identity: p.target), resources: .init(), calibration: calibration, inputResources: inputResources))
        descriptor.dimension = 2; calibration.resources = [descriptor]
        XCTAssertNoThrow(try builder.build(p, model: .init(identity: p.target), resources: .init(), calibration: calibration, inputResources: inputResources))
        descriptor.outputBounds = .init(lower: 0, upper: 0.5); calibration.resources = [descriptor]
        XCTAssertThrowsError(try builder.build(p, model: .init(identity: p.target), resources: .init(), calibration: calibration, inputResources: inputResources))
    }

    func testPackageReplayRejectsForeignSourceRecipeAndCalibration() throws {
        let p = project(), builder = try ModelBuilder(renderer: LumeraRenderer(), execution: execution)
        let package = try builder.build(p, model: .init(identity: p.target), resources: .init())
        let model = try package.load().compiled
        let recipe = EffectiveInputRecipe(declared: p.inputRecipe!, backendVersion: "synthetic-v1")
        let recipeDigest = try recipe.digest()
        let source = try p.source.contentIdentity(effectiveRecipeDigest: recipeDigest, working: p.working)
        let calibration = try InputCalibration.unqualifiedReferenceIdentity(working: p.working)
        let stamp = FrameStamp(streamID: "test", generation: 0, index: 7, presentationTime: 0.7, duration: 0.1)
        let observation = FrameObservations(stamp: stamp, sourceID: source, calibrationID: calibration, featureDigest: model.featureDigest)
        var record = DecisionRecord(modelDigest: model.identity, inputRecipeDigest: recipeDigest,
            resourceDigest: Digest.data(try JSON.encode(model.definition.appearance.resources)), context: .init(evaluationStamp: stamp, observations: observation), seed: 42,
            currentInput: .init(stamp: stamp, inputID: "pixels", sourceID: source, calibrationID: calibration,
                effectiveRecipeDigest: recipeDigest, captureConditions: .init(), effectiveRecipe: recipe))
        XCTAssertNoThrow(try package.validateReplayInputs([record]))
        for kind in ["source", "calibration", "missingRecipe", "changedRecipe"] {
            var effective = recipe
            if kind == "changedRecipe" { effective.declared.version = "2" }
            record.inputRecipeDigest = try effective.digest()
            record.currentInput = .init(stamp: stamp, inputID: "pixels", sourceID: kind == "source" ? "foreign" : source,
                calibrationID: kind == "calibration" ? "foreign" : calibration, effectiveRecipeDigest: record.inputRecipeDigest,
                captureConditions: .init(), effectiveRecipe: kind == "missingRecipe" ? nil : effective)
            XCTAssertThrowsError(try package.validateReplayInputs([record]), kind)
        }
    }

}
