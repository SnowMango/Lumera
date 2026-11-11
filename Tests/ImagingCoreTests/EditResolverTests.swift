import XCTest
@testable import ImagingCore

final class EditResolverTests: XCTestCase {
    private func fixture(_ configure: (inout CameraModel) -> Void = { _ in }) throws -> (CompiledCameraModel, AutomaticControls) {
        var definition = CameraModel(identity: .init(id: "edit", camera: "test", mode: "standard"))
        // Declare only the controls exercised below, within the persisted array budget.
        definition.edits.overrideTargets = [
            "detail.fineSigma", "detail.midSigma", "detail.fineGain", "color.matrix", "color.matrix.0",
            "color.whiteBalance.destination.x", "color.whiteBalance.destination.y", "color.exposureEV",
            "tone.curve", "style.lutWeights"
        ]
        definition.edits.visualControls = [.init(id: "texture", unit: .normalized, bounds: .init(lower: -1, upper: 1), links: [.init(target: "detail.fineSigma", coefficient: 4)])]
        configure(&definition)
        let model = try CameraModelCompiler.compile(definition)
        return (model, AutomaticControls(parameters: definition.appearance.parameters, lutWeights: definition.appearance.lutWeights, modelID: model.identity, sourceID: "source", calibrationID: "calibration", featureDigest: model.featureDigest))
    }
    func testDefaultIsIdentity() throws {
        let (model, automatic) = try fixture()
        let result = try EditResolver.resolve(.init(), automatic: automatic, model: model)
        XCTAssertEqual(result.parameters, automatic.parameters)
        XCTAssertEqual(result.automatic, automatic)
        XCTAssertEqual(result.lutWeights, automatic.lutWeights)
    }
    func testOffsetsThenOverridesThenConstraints() throws {
        let (model, automatic) = try fixture()
        var edits = EditRequest()
        edits.visualOffsets = [.init(id: "texture", value: 1)]
        edits.locks = [.init(target: "detail.fineSigma", value: .scalar(5))]
        let result = try EditResolver.resolve(edits, automatic: automatic, model: model)
        XCTAssertEqual(result.parameters.detail.fineSigma, 5)
        XCTAssertEqual(result.parameters.detail.midSigma, 5)
        XCTAssertEqual(result.lockedTargets, ["detail.fineSigma"])
        XCTAssertFalse(result.diagnostics.isEmpty)
    }
    func testContradictoryLocksReject() throws {
        let (model, automatic) = try fixture()
        var edits = EditRequest()
        edits.locks = [.init(target: "detail.fineSigma", value: .scalar(5)), .init(target: "detail.midSigma", value: .scalar(2))]
        XCTAssertThrowsError(try EditResolver.resolve(edits, automatic: automatic, model: model))
    }
    func testInputExposureDoesNotChangeObservationsOrEXIF() throws {
        let (model, automatic) = try fixture()
        var edits = EditRequest(); edits.inputExposureEV = 2
        edits.inputWhiteBalance = .init(source: .d65, destination: .init(x: 0.3, y: 0.3))
        let result = try EditResolver.resolve(edits, automatic: automatic, model: model)
        XCTAssertEqual(result.automatic, automatic)
        XCTAssertEqual(result.parameters, automatic.parameters)
        XCTAssertEqual(result.inputExposureEV, 2)
        XCTAssertEqual(result.inputWhiteBalance, edits.inputWhiteBalance)
    }
    func testDuplicateControlRejects() throws {
        let (model, automatic) = try fixture()
        var edits = EditRequest()
        edits.overrides = [.init(target: "detail.fineGain", value: .scalar(1))]
        edits.locks = edits.overrides
        XCTAssertThrowsError(try EditResolver.resolve(edits, automatic: automatic, model: model))
        edits.overrides = [.init(target: "color.matrix", value: .matrix(.init()))]
        edits.locks = [.init(target: "color.matrix.0", value: .scalar(1))]
        XCTAssertThrowsError(try EditResolver.resolve(edits, automatic: automatic, model: model))
        edits = .init(); edits.visualOffsets = [.init(id: "texture", value: 0), .init(id: "texture", value: 0)]
        XCTAssertThrowsError(try EditResolver.resolve(edits, automatic: automatic, model: model))
    }
    func testInvalidAndUnsupportedEditsReject() throws {
        let (model, automatic) = try fixture { $0.edits.overrideTargets = [] }
        for override in [ControlOverride(target: "detail.fineGain", value: .scalar(1)), .init(target: "unknown", value: .scalar(0)), .init(target: "detail.fineGain", value: .scalar(.nan))] {
            var edits = EditRequest(); edits.overrides = [override]
            XCTAssertThrowsError(try EditResolver.resolve(edits, automatic: automatic, model: model))
        }
        var edits = EditRequest(); edits.strength = 1
        XCTAssertThrowsError(try EditResolver.resolve(edits, automatic: automatic, model: model))
        edits = .init(); edits.inputExposureEV = .infinity
        XCTAssertThrowsError(try EditResolver.resolve(edits, automatic: automatic, model: model))
    }
    func testWhitePointConstraintPreservesLock() throws {
        let (model, automatic) = try fixture()
        var edits = EditRequest(); edits.locks = [.init(target: "color.whiteBalance.destination.x", value: .scalar(0.8))]
        let result = try EditResolver.resolve(edits, automatic: automatic, model: model)
        XCTAssertEqual(result.parameters.color.whiteBalance.destination.x, 0.8)
        XCTAssertLessThan(result.parameters.color.whiteBalance.destination.y, 0.2)
        try result.parameters.validate(resolved: true)
        edits.locks.append(.init(target: "color.whiteBalance.destination.y", value: .scalar(0.4)))
        XCTAssertThrowsError(try EditResolver.resolve(edits, automatic: automatic, model: model))
    }
    func testDeclaredStrengthEndpointsAndMidpoint() throws {
        let neutral = StyleParameters()
        let (model, automatic) = try fixture {
            $0.edits.strength = .init(neutralParameters: neutral)
            $0.appearance.parameters.color.matrix.values[0] = 1.5
            $0.appearance.parameters.glow.enabled = true
            $0.appearance.parameters.glow.amount = 0.6
            $0.appearance.parameters.glow.nearSigma = 6
        }
        for strength in [0.0, 0.5, 1.0] {
            var edits = EditRequest(); edits.strength = strength; edits.inputExposureEV = 1
            let result = try EditResolver.resolve(edits, automatic: automatic, model: model)
            XCTAssertEqual(result.parameters.color.matrix.values[0], 1 + 0.5 * strength)
            XCTAssertEqual(result.parameters.glow.amount, 0.6 * strength)
            XCTAssertGreaterThan(result.parameters.glow.nearSigma, 0)
            XCTAssertEqual(result.inputExposureEV, 1)
            try result.parameters.validate(resolved: true)
            if strength == 0 { XCTAssertEqual(result.parameters, neutral) }
            if strength == 1 { XCTAssertEqual(result.parameters, automatic.parameters) }
        }
    }
    func testDisabledStoredAmountsDoNotJumpAtPositiveStrength() throws {
        let (model, automatic) = try fixture {
            var neutral = StyleParameters(); neutral.glow.amount = 0.9; neutral.detail.fineGain = 0.1
            $0.edits.strength = .init(neutralParameters: neutral)
            $0.appearance.parameters.glow.enabled = true; $0.appearance.parameters.glow.amount = 0.6
            $0.appearance.parameters.detail.enabled = true; $0.appearance.parameters.detail.fineGain = 0.5
        }
        var edits = EditRequest(); edits.strength = 0.001
        let result = try EditResolver.resolve(edits, automatic: automatic, model: model)
        XCTAssertEqual(result.parameters.glow.amount, 0.0006, accuracy: 1e-12)
        XCTAssertEqual(result.parameters.detail.fineGain, 0.9995, accuracy: 1e-12)
    }
    func testStrengthDoesNotChangeAbsoluteLocks() throws {
        let (model, automatic) = try fixture { $0.edits.strength = .init(neutralParameters: .init()) }
        var edits = EditRequest(); edits.strength = 0
        edits.locks = [.init(target: "color.exposureEV", value: .scalar(2))]
        XCTAssertEqual(try EditResolver.resolve(edits, automatic: automatic, model: model).parameters.color.exposureEV, 2)
    }
    func testStrengthBlendsDisabledToneIdentityWithDeclaredLinearPoints() throws {
        let (model, automatic) = try fixture {
            $0.edits.strength = .init(neutralParameters: .init())
            $0.appearance.parameters.tone.enabled = true
            $0.appearance.parameters.tone.curve = .init(knots: [.init(x: 0, y: 0), .init(x: 0.5, y: 0.7), .init(x: 1, y: 1)])
        }
        var edits = EditRequest(); edits.strength = 0.5
        let result = try EditResolver.resolve(edits, automatic: automatic, model: model)
        XCTAssertEqual(result.parameters.tone.curve.value(at: 0.5), 0.6, accuracy: 1e-12)
    }
    func testUnrepresentableStrengthCurvesReject() throws {
        XCTAssertThrowsError(try fixture {
            $0.edits.strength = .init(neutralParameters: .init())
            $0.appearance.parameters.tone.enabled = true
            $0.appearance.parameters.tone.curve = .init(function: .init(family: .power))
        })
    }
    func testMissingNeutralLUTRejectsAndDeclaredLUTBlendIsConvex() throws {
        let (model, automatic) = try fixture {
            $0.appearance.resources = ["neutral", "target"].map { .init(id: $0, sha256: String(repeating: "a", count: 64), dimension: 2) }
            $0.appearance.lutWeights = [.init(resourceID: "target", weight: 1)]
            $0.edits.strength = .init(neutralParameters: .init(), neutralLUTWeights: [.init(resourceID: "neutral", weight: 1)])
        }
        var edits = EditRequest(); edits.strength = 0.5
        let result = try EditResolver.resolve(edits, automatic: automatic, model: model)
        XCTAssertEqual(result.lutWeights, [.init(resourceID: "neutral", weight: 0.5), .init(resourceID: "target", weight: 0.5)])
        XCTAssertThrowsError(try EditResolver.validateStrength(.init(neutralParameters: .init()), parameters: automatic.parameters, lutWeights: automatic.lutWeights, resources: model.definition.appearance.resources))
        edits = .init(); edits.overrides = [.init(target: "style.lutWeights", value: .resourceWeights([.init(resourceID: "missing", weight: 1)]))]
        XCTAssertThrowsError(try EditResolver.resolve(edits, automatic: automatic, model: model))
    }
    func testDisabledInputCapabilitiesRejectAndIdentityMismatchRejects() throws {
        let (model, automatic) = try fixture { $0.edits.allowsInputExposure = false; $0.edits.allowsInputWhiteBalance = false }
        var edits = EditRequest(); edits.inputExposureEV = 1
        XCTAssertThrowsError(try EditResolver.resolve(edits, automatic: automatic, model: model))
        edits = .init(); edits.inputWhiteBalance = .init()
        XCTAssertThrowsError(try EditResolver.resolve(edits, automatic: automatic, model: model))
        var foreign = automatic; foreign.modelID = "foreign"
        XCTAssertThrowsError(try EditResolver.resolve(.init(), automatic: foreign, model: model))
    }

    func testLinkedOffsetsAccumulateBeforeClampingRegardlessOfRequestOrder() throws {
        let (model, automatic) = try fixture {
            $0.appearance.parameters.color.shift.redGreen = 0.9
            $0.edits.visualControls = ["plus", "minus"].map { .init(id: $0, unit: .normalized, bounds: .init(lower: -1, upper: 1), links: [.init(target: "color.shift.redGreen", coefficient: 1)]) }
        }
        var edits = EditRequest(); edits.visualOffsets = [.init(id: "plus", value: 1), .init(id: "minus", value: -1)]
        let forward = try EditResolver.resolve(edits, automatic: automatic, model: model)
        edits.visualOffsets.reverse()
        let reverse = try EditResolver.resolve(edits, automatic: automatic, model: model)
        XCTAssertEqual(forward.parameters, reverse.parameters)
        XCTAssertEqual(forward.parameters.color.shift.redGreen, 0.9, accuracy: 1e-12)
    }

}
