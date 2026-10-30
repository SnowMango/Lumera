import XCTest
import ImagingCore
@testable import ImageRendering
final class IndependentLUTTests:XCTestCase {
    func testSeparateAssetAndConfigurationIdentity() throws {
        let h=try RenderHarness(precision:.float32),p=Profile.standard
        let data=try JSON.encode(p),text=String(decoding:data,as:UTF8.self)
        XCTAssertFalse(text.contains("cubeText"));XCTAssertFalse(text.contains("\"lut\""))
        let lut=Self.asset(0.5),input=try h.texture(width:4,height:4)
        let request=RenderRequest(input:InputDescriptor(width:4,height:4))
        let baseline=try h.encoder.prepare(ResolvedStyle(profile:p))
        XCTAssertTrue(try h.encode(input,baseline,request) === input)
        let prepared=try h.encoder.prepare(ResolvedStyle(profile:p),lut:lut)
        XCTAssertEqual(RenderHarness.read(try h.encode(input,prepared,request))[0],0.25,accuracy:0.0001)
        var changed=p;changed.parameters.color.exposureEV=1
        _=try h.encoder.prepare(ResolvedStyle(profile:changed),lut:lut)
        XCTAssertEqual(h.encoder.staticResourceStatistics.lutParses,1)
        XCTAssertEqual(h.encoder.staticResourceStatistics.lutUploads,1)
        let different=try h.encoder.prepare(ResolvedStyle(profile:p),lut:Self.asset(0.25))
        XCTAssertEqual(RenderHarness.read(try h.encode(input,different,request))[0],0.125,accuracy:0.0001)
        XCTAssertEqual(try JSON.encode(p),data)
    }
    func testChangingCorrectionMatrixReusesLUTUpload() throws {
        let h=try RenderHarness(),lut=Self.asset(0.5)
        var c=DeviceCorrection();_=try h.encoder.prepareCorrection(c,lut:lut)
        c.matrix.values[0]=0.9;_=try h.encoder.prepareCorrection(c,lut:lut)
        XCTAssertEqual(h.encoder.staticResourceStatistics.lutParses,1)
        XCTAssertEqual(h.encoder.staticResourceStatistics.lutUploads,1)
    }
    func testCorruptAssetRejectedBeforeUse() throws {
        let h=try RenderHarness();var lut=Self.asset(1);lut.sha256="wrong"
        XCTAssertThrowsError(try h.encoder.prepare(ResolvedStyle(profile:.standard),lut:lut))
    }
    static func asset(_ scale:Double)->LUTAsset {
        var lines=["LUT_3D_SIZE 2"]
        for b in 0...1 {for g in 0...1 {for r in 0...1 {lines.append("\(Double(r)*scale) \(Double(g)*scale) \(Double(b)*scale)")}}}
        return LUTAsset(name:"same name",cubeText:lines.joined(separator:"\n"))
    }
}
