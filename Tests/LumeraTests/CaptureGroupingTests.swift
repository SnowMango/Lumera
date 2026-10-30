import XCTest
import ImagingCore
@testable import ImageAnalysis
final class CaptureGroupingTests:XCTestCase {
    func testDeterministicGroupingRejectsDuplicateMissingAndWrongMetadata() throws {
        let p=try CaptureProtocol(input:.init(id:"a",isoLevels:[100,400,1600],baseExposureSeconds:0.01),target:.init(id:"b",isoLevels:[80,320,1250],baseExposureSeconds:0.02))
        let files=p.steps.map {step -> CaptureFile in
            var c=CaptureConditions();c.iso=step.expectedISO;c.exposureDurationSeconds=step.expectedExposureSeconds
            return .init(url:URL(fileURLWithPath:"/test/"+step.id+".jpg"),digest:step.id,role:step.role,target:step.target,conditions:c)
        }
        let a=CaptureGrouping.group(files:files,protocol:p),b=CaptureGrouping.group(files:files.reversed(),protocol:p)
        XCTAssertTrue(a.canMeasure);XCTAssertEqual(a,b);XCTAssertEqual(a.records.count,144)
        XCTAssertFalse(CaptureGrouping.group(files:Array(files.dropLast()),protocol:p).canMeasure)
        XCTAssertFalse(CaptureGrouping.group(files:files+[files[0]],protocol:p).canMeasure)
        var bad=files;bad[0].conditions.iso=nil
        XCTAssertFalse(CaptureGrouping.group(files:bad,protocol:p).canMeasure)
        bad=files;bad[0].role = .target
        XCTAssertFalse(CaptureGrouping.group(files:bad,protocol:p).canMeasure)
    }
}
