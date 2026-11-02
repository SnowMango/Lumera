import XCTest
import ImagingCore
@testable import ImageRendering

final class ExecutionPlanTests: XCTestCase {
    func testOnlyDependentResourcesChange() throws {
        var p = try StylePresets.make("film-demo").parameters
        let plan = PreparedExecutionPlan(parameters:p,color:try ColorTransform.prepare(p.color))
        let first = plan.counts
        p.grain.amount *= 0.5; p.halation.amount = 0.8
        _ = plan.grain(for:p.grain); _ = plan.halation(for:p.halation)
        XCTAssertEqual(plan.counts.grains,first.grains); XCTAssertEqual(plan.counts.halations,first.halations)
        _ = try plan.color(for:p.color); XCTAssertEqual(plan.counts.colors,1)
        p.color.exposureEV = -1; _ = try plan.color(for:p.color); _ = try plan.color(for:p.color)
        XCTAssertEqual(plan.counts.colors,2)
        p.grain.roughness = 0.73; _ = plan.grain(for:p.grain)
        XCTAssertEqual(plan.counts.grains,first.grains+1); XCTAssertEqual(plan.counts.halations,first.halations)
    }

    func testResourceRoleAndRenderIdentity() throws {
        let lut = IndependentLUTTests.asset(0.5), resources = RenderResources(lut:lut)
        let entry = ResourceReferences.Entry(id:"caller-selected",sha256:lut.sha256,contract:lut.contract)
        try resources.validate(against: .init(styleLUT:entry))
        XCTAssertThrowsError(try resources.validate(against: .init(correctionLUT:entry)))
        var profile = try StylePresets.make("film-demo"); profile.temporalPolicy.grain = .fixed
        var request = RenderRequest(input:.init(width:80,height:60)); let style = try ResolvedStyle(profile:profile)
        func identity(_ revision: String) throws -> String {
            try RenderIdentity.make(style:style,resources:resources,request:request,precision:.float32,rendererRevision:revision)
        }
        let id = try identity("first"); request.frameIndex += 1
        XCTAssertEqual(try identity("first"),id); XCTAssertNotEqual(try identity("next"),id)
        request.seed += 1; XCTAssertNotEqual(try identity("first"),id)
        XCTAssertEqual(style.profileDigest,try profile.effectDigest())
    }
}
