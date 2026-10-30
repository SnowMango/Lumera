import XCTest
@testable import ImagingCore
final class DeviceCorrectionTests:XCTestCase {
    func testCorrectionRoundTripAndContentDigest() throws {
        let neutral=DeviceCorrection();try neutral.validate()
        var c=neutral;c.matrix.values=[0,1,0,0,0,1,1,0,0]
        XCTAssertEqual(try JSONDecoder().decode(DeviceCorrection.self,from:JSON.encode(c)),c)
        XCTAssertNotEqual(try c.effectDigest(),try neutral.effectDigest())
        let before=try c.effectDigest();c.whiteBalance.destination=Chromaticity(x:0.3457,y:0.3585)
        XCTAssertNotEqual(try c.effectDigest(),before)
    }
    func testEmbeddedLUTIsRejectedRatherThanSilentlyIgnored() throws {
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:JSON.encode(DeviceCorrection())) as? [String:Any])
        object["lut"]=["cubeText":"old payload"]
        XCTAssertThrowsError(try JSONDecoder().decode(DeviceCorrection.self,from:JSONSerialization.data(withJSONObject:object)))
        object=try XCTUnwrap(JSONSerialization.jsonObject(with:JSON.encode(Profile.standard)) as? [String:Any])
        var parameters=try XCTUnwrap(object["parameters"] as? [String:Any]);parameters["lut"]=["cubeText":"old payload"];object["parameters"]=parameters
        XCTAssertThrowsError(try JSONDecoder().decode(Profile.self,from:JSONSerialization.data(withJSONObject:object)))
    }
    func testInvalidCorrectionRejected() throws {
        var c=DeviceCorrection();c.matrix.values=[];XCTAssertThrowsError(try c.validate())
        c=DeviceCorrection();c.matrix.values[0] = .infinity;XCTAssertThrowsError(try c.validate())
        c=DeviceCorrection();c.whiteBalance.destination=Chromaticity(x:0.7,y:0.5);XCTAssertThrowsError(try c.validate())
        XCTAssertFalse(String(decoding:try JSON.encode(DeviceCorrection()),as:UTF8.self).contains("lut"))
    }
}
