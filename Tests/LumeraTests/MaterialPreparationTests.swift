@testable import ImageAnalysis
import XCTest
import ImagingCore
@testable import ImageRendering

final class MaterialPreparationTests:XCTestCase {
    func testMemoryNormalizationMatchesExistingPNGMaterialRoundTrip() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:folder)}
        for fixture in Fixture.allCases {
            var frame=try Fixtures.make(fixture,width:97,height:65)
            frame.pixels[0] = -0.01;frame.pixels[4]=1.1
            let file=folder.appendingPathComponent(fixture.rawValue+".png")
            try ImageCodec.encode(frame).write(to:file)
            let expected=try ImageCodec.load(file)
            let actual=try ImageCodec.normalizedMaterial(frame)
            let differences=actual.pixels.indices.filter{actual.pixels[$0] != expected.pixels[$0]}
            XCTAssertTrue(differences.isEmpty,"\(fixture.rawValue) differences=\(differences.count) first=\(differences.prefix(4).map{"\($0):\(actual.pixels[$0])/\(expected.pixels[$0])"})")
        }
    }
    func testTransparentNormalizationRetainsLegacyQuantization() throws {
        var input=try Fixtures.make(.patches,width:64,height:48);input.pixels[3]=0.4
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".png")
        defer{try? FileManager.default.removeItem(at:url)}
        try ImageCodec.encode(input).write(to:url)
        let actual=try ImageCodec.normalizedMaterial(input),expected=try ImageCodec.load(url)
        XCTAssertTrue(actual.pixels==expected.pixels)
    }
}
