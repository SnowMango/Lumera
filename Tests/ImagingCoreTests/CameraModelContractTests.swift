import XCTest
@testable import ImagingCore

final class CameraModelContractTests: XCTestCase {
    func testModelRoundTripAndRejectUnknownVersion() throws {
        let model = CameraModel(identity: .init(id: "fixture", camera: "synthetic", mode: "neutral"))
        let bytes = try CameraModelCodec.encode(model)
        XCTAssertEqual(try CameraModelCodec.decode(bytes), model)
        var invalid = model
        invalid.schemaVersion = 2
        XCTAssertThrowsError(try CameraModelCodec.encode(invalid))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        json["schemaVersion"] = 2
        XCTAssertThrowsError(try CameraModelCodec.decode(JSONSerialization.data(withJSONObject: json)))
    }

    func testArrayBudgetsAgreeAcrossModelBoundaries() throws {
        let base = CameraModel(identity: .init(id: "budget", camera: "test", mode: "test"))
        for count in [32, 33, 36, 37] {
            var permissions = base
            permissions.edits.overrideTargets = Array(ParameterSpecification.all.prefix(count)).map(\.id)
            var evidence = base
            evidence.coverage.evidenceDigests = Array(repeating: String(repeating: "a", count: 64), count: count)
            var features = base
            features.observations.features = (0..<count).map { .init(id: "feature-\($0)", statistic: .meanGreen) }
            var resources = base
            resources.appearance.resources = (0..<count).map {
                .init(id: "lut-\($0)", sha256: String(repeating: "a", count: 64), dimension: 2)
            }
            for model in [permissions, evidence, features, resources] {
                try assertBudget(model, accepted: count <= 36)
            }
        }
    }

    func testGridBudgetCountsAllValuesRatherThanEachAxis() throws {
        for (width, height, accepted) in [(4, 8, true), (4, 9, true), (6, 6, true), (6, 7, false), (36, 36, false)] {
            var model = CameraModel(identity: .init(id: "grid", camera: "test", mode: "test"))
            model.observations.sourceConditions = [.iso]
            model.responses = [.init(target: "glow.amount", expression: .twoAxisGrid(
                xAxis: .source(.iso), yAxis: .target(.iso),
                x: (1...width).map { Double($0 * 100) }, y: (1...height).map { Double($0 * 100) },
                values: Array(repeating: .scalar(0.1), count: width * height), boundary: .clamp))]
            try assertBudget(model, accepted: accepted)
        }
    }

    func testSingleAxisResponseAllows36NodesButRejects37() throws {
        for count in [36, 37] {
            var model = CameraModel(identity: .init(id: "axis", camera: "test", mode: "test"))
            model.responses = [.init(target: "glow.amount", expression: .singleAxis(
                axis: .target(.iso), nodes: (1...count).map { .init(Double($0 * 100), .scalar(0.1)) },
                boundary: .clamp))]
            try assertBudget(model, accepted: count == 36)
        }
    }

    private func assertBudget(_ model: CameraModel, accepted: Bool,
                              file: StaticString = #filePath, line: UInt = #line) throws {
        // Raw encoding deliberately bypasses the codec to exercise untrusted input rejection.
        let raw = try JSONEncoder().encode(model)
        if accepted {
            XCTAssertNoThrow(try model.validate(), file: file, line: line)
            XCTAssertNoThrow(try CameraModelCompiler.compile(model), file: file, line: line)
            XCTAssertEqual(try CameraModelCodec.decode(CameraModelCodec.encode(model)), model, file: file, line: line)
        } else {
            XCTAssertThrowsError(try model.validate(), file: file, line: line)
            XCTAssertThrowsError(try CameraModelCompiler.compile(model), file: file, line: line)
            XCTAssertThrowsError(try CameraModelCodec.encode(model), file: file, line: line)
            XCTAssertThrowsError(try CameraModelCodec.decode(raw), file: file, line: line)
        }
    }

    func testInvalidResponseValuesAndOwnershipAreRejected() throws {
        var model = CameraModel(identity: .init(id: "fixture", camera: "synthetic", mode: "neutral"))
        model.responses = [.init(target: "glow.amount", expression: .constant(.scalar(.nan)))]
        XCTAssertThrowsError(try model.validate())
        model.responses = [.init(target: "unknown", expression: .constant(.scalar(0)))]
        XCTAssertThrowsError(try model.validate())
        model.responses = [.init(target: "glow.amount", expression: .constant(.scalar(0.5)))]
        XCTAssertNoThrow(try model.validate())
        model.responses.append(model.responses[0])
        XCTAssertThrowsError(try model.validate())
        model.responses = [.init(target: "color.matrix", expression: .constant(.matrix(.init()))),
                           .init(target: "color.matrix.0", expression: .constant(.scalar(1)))]
        XCTAssertThrowsError(try model.validate())
    }

    func testResourceValidationAndUnresolvedWeights() throws {
        var model = CameraModel(identity: .init(id: "fixture", camera: "synthetic", mode: "neutral"))
        let resource = ModelResourceDescriptor(id: "lut", sha256: String(repeating: "a", count: 64), dimension: 17)
        model.appearance.resources = [resource, resource]
        XCTAssertThrowsError(try model.validate())
        model.appearance.resources = [resource]
        model.appearance.lutWeights = [.init(resourceID: "missing", weight: 1)]
        XCTAssertThrowsError(try model.validate())
        model.appearance.lutWeights = [.init(resourceID: "lut", weight: 1)]
        XCTAssertNoThrow(try model.validate())
        model.appearance.resources[0].outputBounds = .init(lower: 2, upper: 1)
        XCTAssertThrowsError(try model.validate())
    }

    func testObservationIdentityAndFiniteStamp() throws {
        let stamp = FrameStamp(streamID: "stream", generation: 1, index: 0, presentationTime: 0, duration: 1 / 30)
        XCTAssertNoThrow(try stamp.validate())
        var bad = stamp
        bad.presentationTime = .infinity
        XCTAssertThrowsError(try bad.validate())
        bad = stamp
        bad.duration = 0
        XCTAssertThrowsError(try bad.validate())
        let model = CameraModel(identity: .init(id: "fixture", camera: "synthetic", mode: "neutral"))
        XCTAssertTrue(model.observations.features.isEmpty, "Constant models require no statistics")
        XCTAssertEqual(ExecutionPrecision.default, .float16)
        XCTAssertThrowsError(try ExecutionBudget(maxInFlightFrames: 0, maxResidentBytes: 1024).validate())
    }

    func testUnknownBoundsAndRAWRecipeAreExplicit() throws {
        var contract = WorkingImageContract(referenceRenditionID: "reference")
        contract.dynamicRange = .edr
        contract.valueBounds = .unknown
        XCTAssertNoThrow(try contract.validate())
        var recipe = InputRecipe(id: "raw", backend: "coreImage", version: "1")
        recipe.rawSettings = [.init(key: .noiseReduction, value: 0.2, allowsUserOverride: true)]
        XCTAssertNoThrow(try recipe.validate())
        recipe.rawSettings.append(recipe.rawSettings[0])
        XCTAssertThrowsError(try recipe.validate())
    }
    func testEveryPolicyResourceReferenceMustResolve() throws {
        var model = CameraModel(identity: .init(id: "fixture", camera: "synthetic", mode: "neutral"))
        let weights = [ResourceWeight(resourceID: "missing", weight: 1)]
        model.edits.strength = .init(neutralParameters: .init(), neutralLUTWeights: weights)
        XCTAssertThrowsError(try model.validate())
        model.edits.strength = nil
        var rule = AdaptationRule(target: "style.lutWeights", timeConstantSeconds: 1)
        rule.expired = .constant(.resourceWeights(weights))
        model.adaptation.rules = [rule]
        XCTAssertThrowsError(try model.validate())
    }

    func testAdaptationCannotOwnMatrixAndCoefficientTogether() throws {
        var policy = AdaptationPolicy()
        policy.rules = [.init(target: "color.matrix", timeConstantSeconds: 1),
                        .init(target: "color.matrix.0", timeConstantSeconds: 2)]
        XCTAssertThrowsError(try policy.validate())
    }

    func testCodecRejectsDuplicateJSONMembers() throws {
        let model = CameraModel(identity: .init(id: "fixture", camera: "synthetic", mode: "neutral"))
        let json = String(decoding: try CameraModelCodec.encode(model), as: UTF8.self)
        let duplicated = json.replacingOccurrences(of: "\"schemaVersion\" : 1", with: "\"schemaVersion\" : 1, \"schemaVersion\" : 1")
        XCTAssertNotEqual(json, duplicated)
        XCTAssertThrowsError(try CameraModelCodec.decode(Data(duplicated.utf8)))
    }

    func testZeroChangeToleranceAndTypedInitialization() throws {
        var requirements = ObservationRequirements()
        requirements.validity.sourceChangeTolerances = [.init(axis: .iso, maxCoordinateDelta: 0)]
        XCTAssertNoThrow(try requirements.validate())
        requirements.validity.sourceChangeTolerances[0].maxCoordinateDelta = -1
        XCTAssertThrowsError(try requirements.validate())
        var policy = AdaptationPolicy()
        var rule = AdaptationRule(target: "glow.amount", timeConstantSeconds: 1)
        rule.initialization = .constant(.scalar(2))
        policy.rules = [rule]
        XCTAssertThrowsError(try policy.validate())
    }

}
