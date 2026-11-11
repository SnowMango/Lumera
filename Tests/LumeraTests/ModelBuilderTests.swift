import XCTest
import ImagingCore
import ImageRendering
@testable import ImageAnalysis

final class ModelBuilderTests: XCTestCase {
    func project() -> CalibrationProject {
        var source = SourceDescriptor(id: "source", path: .processedPhoto); source.recipeID = "ci"
        return .init(id: "synthetic", target: .init(id: "manual", name: "neutral"), source: source,
            inputRecipe: .init(id: "ci", backend: "coreImage", version: "1", decodedRendition: .baseImage),
            working: .init(referenceRenditionID: "reference"), samples: [])
    }
    var execution: ExecutionProfile { .init(width: 4, height: 4, budget: .init(maxInFlightFrames: 1, maxResidentBytes: 32 * 1024 * 1024)) }
    func testManualModelCanBuildAndRoundTripWithoutClaimingMeasured() throws {
        let p = project(), builder = try ModelBuilder(renderer: LumeraRenderer(), execution: execution)
        let fit = try ModelFitResult(model: .init(identity: p.target), resources: .init())
        let package = try builder.build(p, fit: fit)
        let decoded = try JSONDecoder().decode(StyleModelPackage.self, from: JSON.encode(package))
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
        let bad = StyleModelPackage(modelJSON: try StyleModelCodec.encode(changed), resources: package.resources, inputResources: package.inputResources, manifest: package.manifest)
        XCTAssertThrowsError(try bad.load())
        var missing = StyleModel(identity: p.target)
        missing.appearance.resources = [.init(id: "absent", sha256: String(repeating: "a", count: 64), dimension: 2)]
        XCTAssertThrowsError(try builder.build(p, model: missing, resources: .init()))
    }
    func testVisualRevisionUsesRuntimeMappingAndInvalidatesIdentity() throws {
        let p = project(), builder = try ModelBuilder(renderer: LumeraRenderer(), execution: execution)
        var model = StyleModel(identity: p.target)
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
        var model = StyleModel(identity: p.target)
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
        let fit = ModelFitResult(model: .init(identity: p.target), resources: try .init(), calibration: nil,
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

    func testLegacyPackageVerifiesOriginalBindingsAndSavesVersionTwo() async throws {
        let p = project(), builder = try ModelBuilder(renderer: LumeraRenderer(), execution: execution)
        var definition = StyleModel(identity: p.target)
        definition.edits.visualControls = [.init(id: "exposure", unit: .ev, bounds: .init(lower: -1, upper: 1), links: [.init(target: "color.exposureEV", coefficient: 1)])]
        let fresh = try builder.build(p, model: definition, resources: .init())
        var tree = try XCTUnwrap(JSONSerialization.jsonObject(with: fresh.modelJSON) as? [String: Any])
        tree["schemaVersion"] = 1
        tree["identity"] = ["id": "manual", "camera": "fixture", "mode": "neutral", "settings": [:]] as [String: Any]
        let oldBytes = try JSONSerialization.data(withJSONObject: tree, options: [.sortedKeys])
        var manifest = fresh.manifest
        manifest.version = 1
        manifest.modelBytesDigest = Digest.data(oldBytes)
        manifest.modelDigest = try StyleModelCodec.persistedModelDigest(oldBytes)
        let originalProjectBytes = Data(Self.originalProjectV1.utf8)
        let oldProject = try JSONDecoder().decode(CalibrationProject.self, from: originalProjectBytes)
        XCTAssertNotEqual(try oldProject.persistedDigest(), Digest.data(try JSON.encode(oldProject)))
        // Verified using the original v0.3.2 camera-project CLI typed encoder.
        XCTAssertEqual(try oldProject.persistedDigest(), "25d52c67293277465648bdb486e181948fb81587c2a6647256bb0435fddf1200")
        manifest.projectDigest = try oldProject.persistedDigest()
        let old = StyleModelPackage(modelJSON: oldBytes, resources: [:], inputResources: [:], manifest: manifest)
        let oldFit = ModelFitResult(model: try old.load().model, resources: try .init(), calibration: nil,
            baselineDigest: manifest.modelDigest, projectDigest: try oldProject.persistedDigest(), consumedSampleIDs: [],
            measurementDigests: [], conditionDomains: [], trainResidual: nil, tuneResidual: nil, unresolved: [], algorithmVersion: "legacy-test", derivation: .c3ForwardFits)
        let fittedPackage = try builder.build(oldProject, fit: oldFit)
        XCTAssertEqual(fittedPackage.manifest.projectDigest, Digest.data(try JSON.encode(oldProject)))
        let dataset = try DatasetValidator(baseDirectory: FileManager.default.temporaryDirectory).validate(oldProject)
        let validator = try ModelValidator(renderer: LumeraRenderer(), targetSource: p.source, targetRecipe: p.inputRecipe!)
        let report = try await validator.validate(old, dataset: dataset, policy: p.validationPolicy, execution: execution)
        XCTAssertNoThrow(try report.validateBinding(package: old, dataset: dataset, policy: p.validationPolicy, execution: execution, targetSource: p.source, targetRecipe: p.inputRecipe!))
        let pair = try old.migrated(project: oldProject)
        XCTAssertEqual(pair.project, oldProject)
        XCTAssertEqual(pair.package.manifest.projectDigest, Digest.data(try JSON.encode(pair.project)))
        XCTAssertNotEqual(pair.package.manifest.projectDigest, old.manifest.projectDigest)
        let newDataset = try DatasetValidator(baseDirectory: FileManager.default.temporaryDirectory).validate(pair.project)
        _ = try await validator.validate(pair.package, dataset: newDataset, policy: p.validationPolicy, execution: execution)
        XCTAssertThrowsError(try report.validateBinding(package: pair.package, dataset: newDataset, policy: p.validationPolicy, execution: execution, targetSource: p.source, targetRecipe: p.inputRecipe!))
        var edits = EditRequest(); edits.visualOffsets = [.init(id: "exposure", value: 0.2)]
        let revised = try builder.revise(old, project: oldProject, revision: .init(destination: .base, edits: edits), reason: "Legacy pair revision")
        XCTAssertEqual(revised.manifest.projectDigest, Digest.data(try JSON.encode(oldProject)))
        XCTAssertEqual(try revised.load().model.appearance.parameters.color.exposureEV, 0.2, accuracy: 1e-10)
        XCTAssertThrowsError(try old.migrated(project: p))
        let originalDigest = try old.digest()
        XCTAssertEqual(try old.load().model.schemaVersion, 2)
        let saved = try JSONDecoder().decode(StyleModelPackage.self, from: JSON.encode(old))
        XCTAssertEqual(saved.manifest.version, 2)
        XCTAssertEqual(try saved.load().model.appearance, try old.load().model.appearance)
        XCTAssertEqual(old.modelJSON, oldBytes)
        let cube = Data("LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n".utf8)
        var resourceModel = try old.load().model
        resourceModel.appearance.resources = [.init(id: "lut", sha256: Digest.data(cube), dimension: 2)]
        var resourceTree = try XCTUnwrap(JSONSerialization.jsonObject(with: StyleModelCodec.encode(resourceModel)) as? [String: Any])
        resourceTree["schemaVersion"] = 1; resourceTree["identity"] = tree["identity"]
        let resourceBytes = try JSONSerialization.data(withJSONObject: resourceTree)
        var resourceManifestTree = try XCTUnwrap(JSONSerialization.jsonObject(with: JSON.encode(old.manifest)) as? [String: Any])
        resourceManifestTree["modelBytesDigest"] = Digest.data(resourceBytes)
        resourceManifestTree["modelDigest"] = try StyleModelCodec.persistedModelDigest(resourceBytes)
        resourceManifestTree["resourceDigests"] = ["lut": Digest.data(cube)]
        let resourceManifest = try JSONDecoder().decode(ModelPackageManifest.self, from: JSONSerialization.data(withJSONObject: resourceManifestTree))
        let withResource = StyleModelPackage(modelJSON: resourceBytes, resources: ["lut": cube], inputResources: [:], manifest: resourceManifest)
        XCTAssertNoThrow(try withResource.load())
        let resavedResource = try JSONDecoder().decode(StyleModelPackage.self, from: JSON.encode(withResource))
        XCTAssertEqual(resavedResource.resources, withResource.resources)
        XCTAssertNoThrow(try resavedResource.load())
        XCTAssertThrowsError(try StyleModelPackage(modelJSON: resourceBytes, resources: ["lut": cube + Data(" ".utf8)], inputResources: [:], manifest: resourceManifest).load())
        XCTAssertEqual(try old.digest(), originalDigest)
        XCTAssertNotEqual(try saved.digest(), originalDigest)
        manifest.modelDigest = String(repeating: "0", count: 64)
        let tampered = StyleModelPackage(modelJSON: oldBytes, resources: [:], inputResources: [:], manifest: manifest)
        XCTAssertThrowsError(try tampered.load())
        XCTAssertThrowsError(try JSON.encode(tampered))
        manifest = old.manifest
        let whitespace = oldBytes + Data(" ".utf8)
        XCTAssertThrowsError(try StyleModelPackage(modelJSON: whitespace, resources: [:], inputResources: [:], manifest: manifest).load())
    }
    func testLegacyProjectMigratesIdentityAndEncoding() throws {
        var tree = try XCTUnwrap(JSONSerialization.jsonObject(with: JSON.encode(project())) as? [String: Any])
        tree["schemaVersion"] = 1
        tree["target"] = ["id": "manual", "camera": "fixture", "mode": "neutral", "settings": ["contrast": "low"]] as [String: Any]
        let old = try JSONSerialization.data(withJSONObject: tree)
        let migrated = try JSONDecoder().decode(CalibrationProject.self, from: old)
        XCTAssertEqual(migrated.schemaVersion, 2)
        XCTAssertEqual(migrated.target.metadata["settings.contrast"], "low")
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSON.encode(migrated)) as? [String: Any])
        XCTAssertEqual(saved["schemaVersion"] as? Int, 2)
        XCTAssertNil((saved["target"] as? [String: Any])?["camera"])
    }

    private static let originalProjectV1 = #"""
{
  "id" : "synthetic",
  "inputRecipe" : {
    "backend" : "coreImage",
    "decodedRendition" : "baseImage",
    "id" : "ci",
    "rawSettings" : [

    ],
    "version" : "1"
  },
  "samples" : [

  ],
  "schemaVersion" : 1,
  "source" : {
    "id" : "source",
    "path" : "processedPhoto",
    "primaries" : "unknown",
    "range" : {
      "unknown" : {

      }
    },
    "recipeID" : "ci",
    "reference" : "unknown",
    "transfer" : "unknown"
  },
  "target" : {
    "camera" : "fixture",
    "id" : "manual",
    "mode" : "neutral",
    "settings" : {

    }
  },
  "validationPolicy" : {
    "thresholds" : [

    ],
    "version" : "1"
  },
  "working" : {
    "alphaMode" : "opaque",
    "dynamicRange" : "sdr",
    "fullFrame" : true,
    "orientationNormalized" : true,
    "primaries" : "sRGB",
    "reference" : "display",
    "referenceRecipeVersion" : "1",
    "referenceRenditionID" : "reference",
    "referenceWhite" : 1,
    "renditionSemantics" : "frozen reference; preserve scene exposure and white balance",
    "transfer" : "sRGB",
    "valueBounds" : {
      "finite" : {
        "_0" : {
          "lower" : 0,
          "upper" : 1
        }
      }
    },
    "version" : 1,
    "whitePoint" : {
      "x" : 0.31269999999999998,
      "y" : 0.32900000000000001
    }
  }
}
"""#
}
