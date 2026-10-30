import XCTest
@testable import ImagingCore

final class StyleContractTests: XCTestCase {
    func testColorParameterMetadataIsComplete() {
        let ids=Set(ParameterDescriptor.all.map(\.id))
        for id in ["color.shift.redGreen","color.shift.yellowBlue","color.whiteBalance.source.x","color.whiteBalance.source.y","color.whiteBalance.destination.x","color.whiteBalance.destination.y"] {XCTAssertTrue(ids.contains(id))}
        for i in 0..<9 {XCTAssertTrue(ids.contains("color.matrix.\(i)"))}
    }
    func testNeutralProfileAndStrictRoundTrip() throws {
        let p=Profile.standard
        XCTAssertFalse(p.parameters.detail.isActive)
        XCTAssertFalse(p.parameters.noise.isActive)
        XCTAssertFalse(String(decoding:try JSON.encode(p),as:UTF8.self).contains("cubeText"))
        let data=try JSON.encode(p)
        XCTAssertEqual(try JSONDecoder().decode(Profile.self,from:data),p)
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        for key in ["seed","bypass","evidence"] {XCTAssertNil(object[key])}
        object["schemaVersion"]=2
        XCTAssertThrowsError(try JSONDecoder().decode(Profile.self,from:JSONSerialization.data(withJSONObject:object)))
        object["schemaVersion"]=7;object.removeValue(forKey:"parameters")
        XCTAssertThrowsError(try JSONDecoder().decode(Profile.self,from:JSONSerialization.data(withJSONObject:object)))
    }
    func testInvalidParametersAreRejectedBeforeIndexing() throws {
        var p=Profile.standard;p.parameters.noise.curve = .init(knots:zip([0.0,0.18,0.5,0.85,1],[]).map{.init(x:$0,y:$1)})
        XCTAssertThrowsError(try p.validate())
        p = .standard;p.parameters.tone.curve = .init(knots:zip([0.0,0.25,0.5,0.75,1],[0.8,0.25,0.5,0.75,1]).map{.init(x:$0,y:$1)},interpolation:.smooth)
        XCTAssertThrowsError(try p.validate())
        p = .standard;p.parameters.color.matrix.values=[1,2]
        XCTAssertThrowsError(try p.validate())
        p = .standard;p.parameters.grain.amount = .nan
        XCTAssertThrowsError(try p.validate())
    }
    func testInputAndRequestContract() throws {
        let input=InputDescriptor(width:32,height:24)
        try input.validate()
        var bad=input;bad.transfer = .pq
        XCTAssertThrowsError(try bad.validate())
        bad=input;bad.orientationNormalized=false
        XCTAssertThrowsError(try bad.validate())
        bad=input;bad.alphaMode = .premultiplied
        XCTAssertThrowsError(try bad.validate())
        var request=RenderRequest(input:input);request.maximumLongEdge=0
        XCTAssertThrowsError(try request.validate())
    }
    func testWhitePointAndCreativeMatrixValidation() throws {
        var p=Profile.standard
        p.parameters.color.matrix.values=[0.2,0.7,0.1,0.2,0.7,0.1,0.2,0.7,0.1]
        try p.validate() // Singular grayscale matrix is useful, not an invalid inverse.
        p.parameters.color.whiteBalance.source=Chromaticity(x:0.5,y:0.6)
        XCTAssertThrowsError(try p.validate())
        p = .standard;p.parameters.color.matrix.values[0] = .nan
        XCTAssertThrowsError(try p.validate())
    }
}
