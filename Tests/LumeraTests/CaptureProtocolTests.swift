import XCTest
import ImagingCore
@testable import ImageAnalysis
final class CaptureProtocolTests:XCTestCase {
    func testCountsRolesAndHeldOutMiddleCondition() throws {
        let p=try CaptureProtocol(input:.init(id:"phone",isoLevels:[80,320,1250],baseExposureSeconds:0.01),target:.init(id:"camera",isoLevels:[100,400,1600],baseExposureSeconds:0.02))
        XCTAssertEqual(p.steps.count,144);XCTAssertEqual(Set(p.steps.map(\.id)).count,144)
        for role in CaptureRole.allCases {XCTAssertEqual(p.steps.filter{$0.role==role}.count,72)}
        XCTAssertEqual(p.steps.filter{$0.target == .composite}.count,54)
        XCTAssertEqual(p.steps.filter{$0.target == .flat}.count,72)
        XCTAssertEqual(p.steps.filter{$0.target == .light}.count,18)
        for step in p.steps where step.conditionIndex==1 {XCTAssertEqual(step.purpose,.validation)}
        let a=try XCTUnwrap(p.steps.first{$0.role == .input && $0.conditionIndex==2}),b=try XCTUnwrap(p.steps.first{$0.role == .target && $0.conditionIndex==2})
        XCTAssertEqual(a.expectedISO,1250);XCTAssertEqual(b.expectedISO,1600)
        XCTAssertThrowsError(try CaptureProtocol(input:.init(id:"same",isoLevels:[100,400,1600],baseExposureSeconds:0.01),target:.init(id:"same",isoLevels:[100,400,1600],baseExposureSeconds:0.01)))
        XCTAssertThrowsError(try CaptureProtocol(input:.init(id:"a",isoLevels:[100,100,400],baseExposureSeconds:0.01),target:.init(id:"b",isoLevels:[100,400,1600],baseExposureSeconds:0.01)))
    }
}
