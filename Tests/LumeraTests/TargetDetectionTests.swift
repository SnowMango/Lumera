import XCTest
@testable import ImageAnalysis
final class TargetDetectionTests:XCTestCase {
    func testPerspectiveProjectionAndInvalidCorrespondences() throws {
        let layout=TargetLayout.composite
        let source=layout.markers.map(\.center)
        let expected=ProjectiveTransform(coefficients:[1200,50,100,30,1500,90,0.08,0.04,1])
        let found=zip(layout.markers,source).map{DetectedMarker(id:$0.0.id,center:expected.project($0.1))}
        let detected=try TargetDetection.resolve(markers:found,layout:layout,width:1600,height:2000)
        for p in [TargetPoint(x:0.2,y:0.3),TargetPoint(x:0.8,y:0.7)] {
            XCTAssertLessThan(detected.transform.project(p).distance(to:expected.project(p)),0.00001)
        }
        XCTAssertThrowsError(try TargetDetection.resolve(markers:Array(found.dropLast()),layout:layout,width:1600,height:2000))
        XCTAssertThrowsError(try TargetDetection.resolve(markers:found+[found[0]],layout:layout,width:1600,height:2000))
        var bad=found;bad[0].id="wrong-version"
        XCTAssertThrowsError(try TargetDetection.resolve(markers:bad,layout:layout,width:1600,height:2000))
        bad=found;bad[0].center = .init(x:-4,y:10)
        XCTAssertThrowsError(try TargetDetection.resolve(markers:bad,layout:layout,width:1600,height:2000))
    }
}
