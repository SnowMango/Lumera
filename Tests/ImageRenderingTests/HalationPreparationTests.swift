import XCTest
import ImagingCore
@testable import ImageRendering

final class HalationPreparationTests: XCTestCase {
    func testOnlyRadiusRebuildsHalationPreparation() throws {
        var p=StyleParameters()
        p.halation.enabled=true;p.halation.amount=0.2
        let plan=PreparedExecutionPlan(parameters:p,color:try ColorTransform.prepare(p.color))
        let original=plan.halation(for:p.halation)
        p.halation.amount=0.6;p.halation.threshold=0.22;p.halation.blue=0.8
        XCTAssertEqual(plan.halation(for:p.halation).sigmas,original.sigmas)
        XCTAssertEqual(plan.counts.halations,1)
        p.halation.radius*=2
        XCTAssertEqual(plan.halation(for:p.halation).sigmas,original.sigmas.map { $0*2 })
        XCTAssertEqual(plan.counts.halations,2)
        XCTAssertEqual(plan.counts.grains,0)
        XCTAssertEqual(plan.counts.colors,1)
    }
}
