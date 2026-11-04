import XCTest
import ImagingCore

final class RenderRangeTests: XCTestCase {
    func testLegacyOptionsAndRequestsDecodeAsSDRAndEDRForwards() throws {
        func legacy<T: Codable>(_ value: T) throws -> T {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
            object.removeValue(forKey: "dynamicRange")
            return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
        }
        let original = RenderOptions(maximumLongEdge: 512, seed: 91, frameIndex: 4)
        XCTAssertEqual(try legacy(original), original)
        let request = original.makeRequest(input: .init(width: 800, height: 600))
        XCTAssertEqual(try legacy(request), request)
        var edr = original; edr.dynamicRange = .edr
        let forwarded = edr.makeRequest(input: request.input)
        XCTAssertEqual(forwarded.dynamicRange, .edr)
        XCTAssertEqual(try JSONDecoder().decode(RenderRequest.self, from: JSONEncoder().encode(forwarded)), forwarded)
        XCTAssertEqual(try JSONDecoder().decode(RenderOptions.self, from: JSONEncoder().encode(edr)), edr)
    }

    func testUnknownDynamicRangeIsRejectedRatherThanTreatedAsSDR() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(RenderOptions())) as? [String: Any])
        object["dynamicRange"] = "unknown"
        XCTAssertThrowsError(try JSONDecoder().decode(RenderOptions.self, from: JSONSerialization.data(withJSONObject: object)))
    }
}
