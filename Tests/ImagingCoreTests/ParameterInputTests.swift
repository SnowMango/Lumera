import XCTest
@testable import ImagingCore

final class ParameterInputTests: XCTestCase {
    func testRejectAndClampUseDeclaredDomain() throws {
        var p = StyleParameters(), weights: [ResourceWeight] = []
        let roughness = ControlOverride(target: "grain.roughness", value: .scalar(2))
        XCTAssertThrowsError(try ParameterInput.update([roughness], parameters: &p, lutWeights: &weights))
        XCTAssertEqual(p.grain.roughness, 0.35)
        let diagnostics = try ParameterInput.update([roughness], parameters: &p, lutWeights: &weights, behavior: .clamp)
        XCTAssertEqual(p.grain.roughness, 1)
        XCTAssertEqual(diagnostics.first?.code, .clamped)
        let exposure = ControlOverride(target: "color.exposureEV", value: .scalar(15))
        XCTAssertThrowsError(try ParameterInput.update([exposure], parameters: &p, lutWeights: &weights))
        _ = try ParameterInput.update([exposure], parameters: &p, lutWeights: &weights, domain: .effective)
        XCTAssertEqual(p.color.exposureEV, 15)
    }

    func testNonfiniteAndGroupedUpdatesAreAtomic() throws {
        var p = StyleParameters(), weights: [ResourceWeight] = []
        for number in [Double.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try ParameterInput.update([.init(target: "grain.roughness", value: .scalar(number))],
                parameters: &p, lutWeights: &weights, behavior: .clamp))
        }
        // The intermediate x + old y is invalid; the final pair is valid.
        _ = try ParameterInput.update([
            .init(target: "color.whiteBalance.source.x", value: .scalar(0.8)),
            .init(target: "color.whiteBalance.source.y", value: .scalar(0.1))], parameters: &p, lutWeights: &weights)
        XCTAssertEqual(p.color.whiteBalance.source, .init(x: 0.8, y: 0.1))
        let before = p
        XCTAssertThrowsError(try ParameterInput.update([
            .init(target: "color.exposureEV", value: .scalar(1)),
            .init(target: "color.whiteBalance.source.y", value: .scalar(0.5))], parameters: &p, lutWeights: &weights))
        XCTAssertEqual(p, before)
        XCTAssertThrowsError(try ParameterInput.update([
            .init(target: "color.exposureEV", value: .scalar(1)),
            .init(target: "color.matrix", value: .matrix(.init(values: [1, 2])))], parameters: &p, lutWeights: &weights))
        XCTAssertEqual(p, before)
        XCTAssertThrowsError(try ParameterInput.update([
            .init(target: "color.exposureEV", value: .scalar(1)),
            .init(target: "style.lutWeights", value: .resourceWeights([.init(resourceID: "a", weight: 0.3)]))],
            parameters: &p, lutWeights: &weights))
        XCTAssertEqual(p, before); XCTAssertTrue(weights.isEmpty)
    }

    func testChangedFieldDoesNotScanDisabledEffects() throws {
        var p = StyleParameters(), weights: [ResourceWeight] = []
        p.grain.enabled = false; p.grain.roughness = 2
        _ = try ParameterInput.update([.init(target: "color.exposureEV", value: .scalar(1))], parameters: &p, lutWeights: &weights)
        XCTAssertEqual(p.color.exposureEV, 1); XCTAssertEqual(p.grain.roughness, 2)
        XCTAssertThrowsError(try ParameterInput.accept(p))
    }

    func testCheckedDecodeIsExplicit() throws {
        var p = Profile.standard; p.parameters.grain.roughness = 2
        let data = try ProfileCodec.encode(p)
        XCTAssertEqual(try ProfileCodec.decode(data).parameters.grain.roughness, 2)
        XCTAssertThrowsError(try ProfileCodec.decodeChecked(data))
        var model = StyleModel(identity: .init(id: "input", name: "input")); model.appearance.parameters = p.parameters
        let modelData = try StyleModelCodec.encode(model)
        XCTAssertEqual(try StyleModelCodec.decode(modelData).appearance.parameters.grain.roughness, 2)
        XCTAssertThrowsError(try StyleModelCodec.decodeChecked(modelData))
    }

    func testCurveAndPolicyInputAreOptionalDiagnostics() throws {
        XCTAssertThrowsError(try ParameterInput.curve(.init(knots: []), kind: .grain))
        XCTAssertEqual(try ParameterInput.curve(.identity, kind: .tone), .identity)
        var policy = AdaptationPolicy(); policy.rules = [.init(target: "grain.amount", timeConstantSeconds: -1)]
        XCTAssertThrowsError(try ParameterInput.adaptationPolicy(policy))
    }
}
