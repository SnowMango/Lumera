import XCTest
@testable import ImagingCore

final class ProfileCodecTests: XCTestCase {
    private func document(_ extra: String = "") -> Data {
        Data(("{\"schemaVersion\":8,\"id\":\"a\",\"name\":\"demo\"" + extra + "}").utf8)
    }

    func testOversizedURLRejectedBeforeDecode() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertTrue(FileManager.default.createFile(atPath:url.path, contents:nil))
        defer { try? FileManager.default.removeItem(at:url) }
        let handle = try FileHandle(forWritingTo:url)
        try handle.truncate(atOffset:UInt64(ProfileCodec.maximumBytes + 1024 * 1024))
        try handle.close()
        XCTAssertThrowsError(try JSON.load(Profile.self,from:url)) { error in
            XCTAssertTrue(error.localizedDescription.contains("16 MiB"))
        }
    }
    func testSchemaDefaultsAndRoundTrip() throws {
        let profile = try ProfileCodec.decode(document(",\"parameters\":{\"grain\":{\"size\":2}}"))
        XCTAssertEqual(profile.parameters.grain.size, 2)
        XCTAssertEqual(profile.parameters.grain.roughness, 0.35)
        XCTAssertEqual(profile.temporalPolicy, TemporalPolicy())
        XCTAssertEqual(try ProfileCodec.decode(ProfileCodec.encode(profile)), profile)
    }

    func testRejectsInvalidBytesAtField() {
        for (extra, path) in [
            (",\"id\":\"duplicate\"", "id"),
            (#", "\u0069d":"escaped duplicate""#, "id"),
            (",\"parameters\":{\"grain\":{\"size\":null}}", "parameters.grain.size"),
            (",\"parameters\":{\"grain\":{\"typo\":2}}", "parameters.grain.typo"),
            (",\"parameters\":{\"grain\":{\"size\":true}}", "parameters.grain.size"),
            (",\"parameters\":{\"grain\":{\"size\":20}}", "parameters.grain.size"),
            (",\"parameters\":{\"halation\":{\"sigma\":4}}", "parameters.halation.sigma")
        ] {
            XCTAssertThrowsError(try ProfileCodec.decode(document(extra))) {
                XCTAssertTrue($0.localizedDescription.contains(path), $0.localizedDescription)
            }
        }
        let old = Data(#"{"schemaVersion":7,"id":"old","name":"old"}"#.utf8)
        XCTAssertThrowsError(try ProfileCodec.decode(old)) { XCTAssertTrue($0.localizedDescription.contains("schemaVersion")) }
        XCTAssertThrowsError(try ProfileCodec.decode(Data(repeating: 32, count: 16 * 1024 * 1024 + 1)))
        let deep = String(repeating: "[", count: 65) + "0" + String(repeating: "]", count: 65)
        XCTAssertThrowsError(try ProfileCodec.decode(document(",\"depth\":" + deep)))
    }

    func testInvalidFileIsReadOnly() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bytes = document(",\"parameters\":{\"noise\":{\"gain\":100}}")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try JSON.load(Profile.self, from: url))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testMalformedResponseIdentifiesArrayElement() throws {
        let partial = #", "responses":[{"target":"unknown","axis":"iso","operation":"replace","curve":{"shape":{"points":{"_0":[{"x":100,"y":1},{"x":200,"y":2}]}}}}]"#
        XCTAssertThrowsError(try ProfileCodec.decode(document(partial))) {
            XCTAssertTrue($0.localizedDescription.contains("$.responses[0].target"), $0.localizedDescription)
        }
        let invalidCurve = partial.replacingOccurrences(of: "unknown", with: "grain.size")
            .replacingOccurrences(of: #""x":200"#, with: #""x":90"#)
        XCTAssertThrowsError(try ProfileCodec.decode(document(invalidCurve))) {
            XCTAssertTrue($0.localizedDescription.contains("$.responses[0].curve"), $0.localizedDescription)
        }
    }

    func testEveryResponseHasDescriptorAndUnit() throws {
        for target in ResponseTarget.allCases {
            let descriptor = try XCTUnwrap(target.descriptor)
            XCTAssertTrue(descriptor.isBindable)
            XCTAssertEqual(descriptor.allowedOperations, target.allowedOperations)
            XCTAssertTrue(descriptor.baseRange.contains(descriptor.defaultValue))
        }
        let exposure = try XCTUnwrap(ParameterDescriptor.all.first { $0.id == "color.exposureEV" })
        XCTAssertEqual(exposure.unit, .ev)
        XCTAssertEqual(exposure.effectiveRange, -6...6)
    }
}
