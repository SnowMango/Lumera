import XCTest
import CryptoKit
@testable import ImagingCore

final class DigestTests: XCTestCase {
    func testKnownSHA256VectorsAndBufferIdentity() {
        for (text, expected) in [
            ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
            ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        ] {
            let data = Data(text.utf8)
            XCTAssertEqual(Digest.data(data), expected)
            XCTAssertEqual(data.withUnsafeBytes { Digest.buffer($0) }, expected)
        }
    }

    func testPreservesLegacyHexIncludingLeadingZeros() {
        for length in [1, 31, 32, 63, 64, 255, 256, 4096] {
            let data = Data((0..<length).map { UInt8(truncatingIfNeeded: $0) })
            let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(Digest.data(data), expected)
            XCTAssertEqual(data.withUnsafeBytes { Digest.buffer($0) }, expected)
        }
    }

    func testCompiledResourceIdentityTracksImmutableDefinition() throws {
        var definition = StyleModel(identity: .init(id: "identity", name: "identity"))
        definition.appearance.resources = [.init(id: "lut", sha256: String(repeating: "a", count: 64), dimension: 17)]
        let first = try StyleModelCompiler.compile(definition)
        definition.appearance.resources[0].sha256 = String(repeating: "b", count: 64)
        let second = try StyleModelCompiler.compile(definition)
        XCTAssertEqual(first.resourceDigest, Digest.data(try JSON.encode(first.definition.appearance.resources)))
        XCTAssertEqual(second.resourceDigest, Digest.data(try JSON.encode(second.definition.appearance.resources)))
        XCTAssertNotEqual(first.resourceDigest, second.resourceDigest)
    }
}
