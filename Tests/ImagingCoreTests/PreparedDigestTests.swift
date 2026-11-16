import XCTest
@testable import ImagingCore

final class PreparedDigestTests: XCTestCase {
    private var recipe: EffectiveInputRecipe {
        .init(declared: .init(id: "ci", backend: "coreImage", version: "1", decodedRendition: .baseImage), backendVersion: "1")
    }

    func testRecipePreparationPreservesSerializationAndRejectsMutations() throws {
        let original = recipe
        let prepared = try original.preparingDigest()
        XCTAssertEqual(prepared, original)
        XCTAssertEqual(try JSON.encode(prepared), try JSON.encode(original))
        XCTAssertEqual(try prepared.digest(), try original.digest())
        var changed = prepared
        changed.declared.version = "2"
        XCTAssertNotEqual(try changed.digest(), try prepared.digest())
        changed.backendVersion = ""
        XCTAssertThrowsError(try changed.digest())
        changed = prepared
        changed.settings.append(.init(key: .exposureEV, value: .nan))
        XCTAssertThrowsError(try changed.digest())
    }

    func testDecodedRecipeCannotCarryPreparedTrust() throws {
        let prepared = try recipe.preparingDigest()
        let stamp = FrameStamp(streamID: "stream", generation: 1, index: 1, presentationTime: 1, duration: 1 / 30)
        let facts = FrameInputFacts(stamp: stamp, inputID: "input", sourceID: "source", calibrationID: "calibration",
            effectiveRecipeDigest: try prepared.digest(), captureConditions: .init(), effectiveRecipe: prepared)
        let decoded = try JSONDecoder().decode(FrameInputFacts.self, from: JSON.encode(facts))
        XCTAssertEqual(decoded, facts)
        try decoded.validate()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSON.encode(facts)) as? [String: Any])
        var payload = try XCTUnwrap(object["effectiveRecipe"] as? [String: Any])
        payload["backendVersion"] = "tampered"
        payload["preparedDigest"] = try prepared.digest()
        object["effectiveRecipe"] = payload
        let tampered = try JSONDecoder().decode(FrameInputFacts.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try tampered.validate())
    }

    func testFeatureDigestInvalidatesOnNestedChangeAndStillValidatesPolicy() throws {
        var requirements = ObservationRequirements()
        requirements.features = [.init(id: "mean", statistic: .meanRed)]
        let prepared = try requirements.preparingFeatureDigest()
        XCTAssertEqual(try JSON.encode(prepared), try JSON.encode(requirements))
        XCTAssertEqual(prepared, requirements)
        var changed = prepared
        changed.features[0].id = "different"
        XCTAssertNotEqual(try changed.featureDigest(), try prepared.featureDigest())
        changed = prepared
        changed.validity.maxAgeSeconds = -1
        XCTAssertThrowsError(try changed.featureDigest())
    }

    func testCompiledPoliciesReuseIdentitiesWithoutChangingDefinition() throws {
        var policy = AdaptationPolicy()
        policy.rules = [.init(target: "glow.amount", timeConstantSeconds: 1)]
        let prepared = try policy.preparingDigest()
        XCTAssertEqual(try JSON.encode(prepared), try JSON.encode(policy))
        XCTAssertEqual(prepared, policy)
        XCTAssertEqual(try prepared.digest(), try StyleIdentity.digest(policy))
        var changed = prepared
        changed.rules[0].timeConstantSeconds = 2
        XCTAssertNotEqual(try changed.digest(), try prepared.digest())
        changed.rules[0].timeConstantSeconds = -1
        XCTAssertThrowsError(try changed.digest())
    }
}
