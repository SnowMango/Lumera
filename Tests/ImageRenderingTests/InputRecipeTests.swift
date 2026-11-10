import XCTest
import ImagingCore
@testable import ImageRendering

final class InputRecipeTests: XCTestCase {
    func testUnsupportedRAWOverrideRejects() throws {
        var recipe = InputRecipe(id: "raw", backend: "coreImage", version: "1")
        recipe.rawSettings = [.init(key: .sharpness, value: 0.1, allowsUserOverride: true)]
        XCTAssertThrowsError(try RAWRecipeResolver.resolve(recipe, overrides: [.init(key: .sharpness, value: 0.5)], supported: [], defaults: []))
        XCTAssertThrowsError(try RAWRecipeResolver.resolve(recipe, overrides: [.init(key: .exposureEV, value: 1)], supported: [.sharpness, .exposureEV], defaults: []))
        let resolved = try RAWRecipeResolver.resolve(recipe, overrides: [.init(key: .sharpness, value: 0.5)], supported: [.sharpness], defaults: [])
        XCTAssertEqual(resolved.first?.value, 0.5)
    }
    func testRAWSettingsRejectInvalidRangeAndDuplicateOverrides() throws {
        var recipe = InputRecipe(id: "raw", backend: "coreImage", version: "1")
        recipe.rawSettings = [.init(key: .sharpness, value: 0.1, allowsUserOverride: true)]
        XCTAssertThrowsError(try RAWRecipeResolver.resolve(recipe, overrides: [.init(key: .sharpness, value: 2)], supported: [.sharpness], defaults: []))
        XCTAssertThrowsError(try RAWRecipeResolver.resolve(recipe, overrides: [.init(key: .sharpness, value: 0.2), .init(key: .sharpness, value: 0.4)], supported: [.sharpness], defaults: []))
    }
    func testGenericRAWNoiseSettingRequiresBothBackendControls() throws {
        var recipe = InputRecipe(id: "raw", backend: "coreImage", version: "1")
        recipe.rawSettings = [.init(key: .noiseReduction, value: 0.2)]
        XCTAssertThrowsError(try RAWRecipeResolver.resolve(recipe, overrides: [], supported: [.noiseReduction], defaults: []))
        let result = try RAWRecipeResolver.resolve(recipe, overrides: [], supported: [.noiseReduction, .luminanceNoiseReduction, .colorNoiseReduction], defaults: [])
        XCTAssertEqual(Set(result.map(\.key)), [.luminanceNoiseReduction, .colorNoiseReduction])
        XCTAssertEqual(result.map(\.value), [0.2, 0.2])
    }

}

extension InputRecipeTests {
    func testLegacyEffectiveRAWDigestRemainsStable() throws {
        let legacy = Data("""
            {"declared":{"id":"raw","backend":"coreImage","version":"1","rawSettings":[]},
             "backendVersion":"fixture-os","decoderVersion":"fixture-decoder",
             "settings":[{"key":"exposureEV","value":0.25,"allowsUserOverride":false}]}
            """.utf8)
        let receipt = try JSONDecoder().decode(EffectiveInputRecipe.self, from: legacy)
        XCTAssertNil(receipt.externalRAWConfiguration)
        XCTAssertEqual(try receipt.digest(), "2d833fe396abb14a26c091bfdee1eb83e35cb53743987341532e7ba3a97ae947")
    }

    func testExternalRAWPayloadIsOwnedAndIdentityBindsIdentifierVersionAndBytes() throws {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 1)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 7, count: 64)
        let borrowed = Data(bytesNoCopy: buffer, count: 64, deallocator: .none)
        let configuration = try RAWDevelopmentConfiguration(identifier: "host", version: "1", payload: borrowed) { _, _ in }
        buffer.storeBytes(of: UInt8(8), as: UInt8.self)
        XCTAssertEqual(configuration.payload, Data(repeating: 7, count: 64))
        XCTAssertEqual(configuration.identity.payloadDigest, Digest.data(Data(repeating: 7, count: 64)))

        let recipe = InputRecipe(id: "raw", backend: "coreImage", version: "1")
        let applied = EffectiveInputRecipe(declared: recipe, backendVersion: "os1", decoderVersion: "decoder1",
                                           externalRAWConfiguration: configuration.identity)
        for (id, version, payload) in [("other", "1", configuration.payload), ("host", "2", configuration.payload), ("host", "1", borrowed)] {
            let changed = try RAWDevelopmentConfiguration(identifier: id, version: version, payload: payload) { _, _ in }
            var different = applied; different.externalRAWConfiguration = changed.identity
            XCTAssertNotEqual(try applied.digest(), try different.digest())
        }
        var different = applied; different.decoderVersion = "decoder2"
        XCTAssertNotEqual(try applied.digest(), try different.digest())
        different = applied; different.backendVersion = "os2"
        XCTAssertNotEqual(try applied.digest(), try different.digest())
    }

    func testExternalRAWRejectsEveryLegacyMutationBeforeOpeningSource() async throws {
        let adapter = try InputAdapter(renderer: LumeraRenderer(), working: .init(referenceRenditionID: "fixture"))
        var descriptor = SourceDescriptor(id: "source", path: .raw); descriptor.recipeID = "raw"
        let recipe = InputRecipe(id: "raw", backend: "coreImage", version: "1")
        let config = try RAWDevelopmentConfiguration(identifier: "host", version: "1", payload: Data()) { _, _ in }
        let execution = ExecutionProfile(width: 1, height: 1, budget: .init(maxInFlightFrames: 1, maxResidentBytes: 1))
        var defaults = recipe; defaults.rawSettings = [.init(key: .exposureEV, value: 0)]
        var decoder = recipe; decoder.decoderVersion = "legacy"
        let requests: [(InputRecipe, [RAWOverride])] = [(defaults, []), (decoder, []), (recipe, [.init(key: .exposureEV, value: 1)])]
        for (declared, overrides) in requests {
            do {
                _ = try await adapter.prepare(.rawData(Data()), descriptor: descriptor, recipe: declared,
                    execution: execution, rawOverrides: overrides, rawConfiguration: config)
                XCTFail("Mixed RAW configuration was accepted")
            } catch LabError.invalid { } catch { XCTFail("Expected conflict before opening the source, got \(error)") }
        }
    }
}
