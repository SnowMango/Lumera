@testable import ImageAnalysis
import XCTest
@testable import ImagingCore
final class CoreTests: XCTestCase {

 func testProfileRoundTripAndValidation() throws {
  let p = TestProfiles.ccd
  XCTAssertEqual(try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(p)), p)
  try p.validate()
  var bad = p; bad.parameters.vignette.amountEV = -1
  XCTAssertThrowsError(try bad.validate())
  bad = p; bad.parameters.glow.nearSigma = .nan
  XCTAssertThrowsError(try bad.validate())
  bad = p; bad.schemaVersion = 999
  XCTAssertThrowsError(try bad.validate())
 }

 func testSafeWriteNeverClobbersExistingFile() throws {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: url) }
  try SafeFiles.write(Data([1,2]), to: url)
  XCTAssertThrowsError(try SafeFiles.write(Data([3]), to: url))
  XCTAssertEqual(try Data(contentsOf:url), Data([1,2]))
 }
 func testLatestRenderRejectsStaleAndCancelledResults() {
  var gate=RenderGate();let old=gate.begin(),latest=gate.begin()
  XCTAssertFalse(gate.accepts(old));XCTAssertTrue(gate.accepts(latest))
  gate.cancel();XCTAssertFalse(gate.accepts(latest))
 }
 func testShortNoiseCurveIsRejected() throws {
  var p = TestProfiles.ccd; p.parameters.noise.curve = .init(knots:zip([0.0,0.18,0.5,0.85,1],[]).map{.init(x:$0,y:$1)})
  XCTAssertThrowsError(try p.validate())
 }
 func testRegionRejectsInvalidCoordinates() throws {
  XCTAssertThrowsError(try Region(x: -1, y: 0, width: 0.5, height: 0.5).validate())
  XCTAssertThrowsError(try Region(x: 0.8, y: 0, width: 0.5, height: 1).validate())
 }
}
