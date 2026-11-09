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
