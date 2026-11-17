import XCTest
import CoreImage
import ImagingCore
@testable import ImageRendering

final class InputIdentityReuseTests: XCTestCase {
    private let working = WorkingImageContract(referenceRenditionID: "identity-fixture")
    private let recipe = InputRecipe(id: "ci", backend: "coreImage", version: "1", decodedRendition: .baseImage)
    private var descriptor: SourceDescriptor {
        var value = SourceDescriptor(id: "camera", path: .processedPhoto)
        value.recipeID = "ci"; value.camera = "wide"
        return value
    }
    private let execution = ExecutionProfile(width: 1, height: 1,
        budget: .init(maxInFlightFrames: 1, maxResidentBytes: 16 * 1024 * 1024))
    private func image(_ value: Double, iso: Int) -> CIImage {
        CIImage(color: CIColor(red: value, green: value, blue: value)).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
            .settingProperties(["{Exif}": ["ISOSpeedRatings": [iso]]])
    }

    func testReusesOnlyConfigurationWhilePixelsAndFrameFactsStayFresh() async throws {
        let renderer = try LumeraRenderer()
        let adapter = try InputAdapter(renderer: renderer, working: working)
        let a = try await adapter.prepare(.image(image(0.2, iso: 100)), descriptor: descriptor, recipe: recipe, execution: execution)
        let b = try await adapter.prepare(.image(image(0.8, iso: 800)), descriptor: descriptor, recipe: recipe, execution: execution)
        XCTAssertTrue(a.identity === b.identity)
        XCTAssertEqual(a.effectiveRecipeDigest, try a.effectiveRecipe.digest())
        XCTAssertEqual(a.sourceID, try descriptor.contentIdentity(effectiveRecipeDigest: a.effectiveRecipe.digest(), working: working))
        XCTAssertEqual(a.sourceID, b.sourceID)
        XCTAssertNotEqual(a.inputID, b.inputID)
        XCTAssertFalse(a.texture === b.texture)
        XCTAssertLessThan(a.valueBounds.upper, b.valueBounds.lower)
        XCTAssertEqual(a.captureConditions.iso, 100)
        XCTAssertEqual(b.captureConditions.iso, 800)
        let normalizer = InputNormalizer(renderer: renderer)
        let prepared = try await normalizer.normalize(b, calibration: nil, resources: .init())
        XCTAssertEqual(prepared.calibrationID, try InputCalibration.unqualifiedReferenceIdentity(working: working))
        let stamp = FrameStamp(streamID: "s", generation: 1, index: 2, presentationTime: 1, duration: 1 / 30)
        let facts = try prepared.photoFacts(stamp: stamp)
        XCTAssertEqual(facts.effectiveRecipeDigest, b.effectiveRecipeDigest)
        XCTAssertEqual(facts.captureConditions.iso, 800)
        XCTAssertEqual(facts.stamp, stamp)
        XCTAssertNoThrow(try facts.validate())
    }

    func testLensRecipeAndWorkingChangesCannotReuseOldIdentity() async throws {
        let renderer = try LumeraRenderer()
        let adapter = try InputAdapter(renderer: renderer, working: working)
        let source = SourceImage.image(image(0.5, iso: 100))
        let a = try await adapter.prepare(source, descriptor: descriptor, recipe: recipe, execution: execution)
        var lens = descriptor; lens.camera = "telephoto"
        let b = try await adapter.prepare(source, descriptor: lens, recipe: recipe, execution: execution)
        var changedRecipe = recipe; changedRecipe.version = "2"
        let c = try await adapter.prepare(source, descriptor: lens, recipe: changedRecipe, execution: execution)
        let restored = try await adapter.prepare(source, descriptor: descriptor, recipe: recipe, execution: execution)
        XCTAssertNotEqual(a.sourceID, b.sourceID)
        XCTAssertNotEqual(b.sourceID, c.sourceID)
        XCTAssertEqual(a.sourceID, restored.sourceID)
        XCTAssertEqual(a.effectiveRecipe.declared.version, "1")
        XCTAssertEqual(a.descriptor.camera, "wide")
        var changedWorking = working; changedWorking.referenceRenditionID = "another-reference"
        let other = try InputAdapter(renderer: renderer, working: changedWorking)
        let d = try await other.prepare(source, descriptor: descriptor, recipe: recipe, execution: execution)
        XCTAssertNotEqual(a.sourceID, d.sourceID)
        XCTAssertNotEqual(a.identity.unqualifiedReferenceID, d.identity.unqualifiedReferenceID)
        var calibration = InputCalibration(id: "wide-calibration", source: descriptor, working: working)
        calibration.recipeDigest = a.effectiveRecipeDigest
        do {
            _ = try await InputNormalizer(renderer: renderer).normalize(c, calibration: calibration, resources: .init())
            XCTFail("Changed source and recipe must reject the old calibration")
        } catch { }
    }

    func testInvalidEffectiveConfigurationIsStillRejected() throws {
        var invalid = EffectiveInputRecipe(declared: recipe, backendVersion: "backend")
        invalid.settings = [.init(key: .exposureEV, value: .nan)]
        XCTAssertThrowsError(try PreparedInputIdentity(descriptor: descriptor, recipe: invalid, working: working))
        invalid.settings = []; invalid.backendVersion = ""
        XCTAssertThrowsError(try PreparedInputIdentity(descriptor: descriptor, recipe: invalid, working: working))
    }

    func testCachePreservesSignedZeroAndUnicodeIdentityBytes() async throws {
        let adapter = try InputAdapter(renderer: LumeraRenderer(), working: working)
        let source = SourceImage.image(image(0.5, iso: 100))
        var negative = descriptor; negative.range = .finite(.init(lower: -0.0, upper: 1))
        var positive = negative; positive.range = .finite(.init(lower: 0.0, upper: 1))
        var composed = descriptor; composed.camera = "caf\u{e9}"
        var decomposed = descriptor; decomposed.camera = "cafe\u{301}"
        var composedRecipe = recipe; composedRecipe.version = "caf\u{e9}"
        var decomposedRecipe = recipe; decomposedRecipe.version = "cafe\u{301}"
        for (descriptor, recipe) in [(negative, recipe), (positive, recipe),
            (composed, recipe), (decomposed, recipe), (self.descriptor, composedRecipe), (self.descriptor, decomposedRecipe)] {
            let input = try await adapter.prepare(source, descriptor: descriptor, recipe: recipe, execution: execution)
            XCTAssertTrue(input.effectiveRecipe.declared.version.utf8.elementsEqual(recipe.version.utf8))
            XCTAssertEqual(input.effectiveRecipeDigest, try input.effectiveRecipe.digest())
            XCTAssertEqual(input.sourceID, try descriptor.contentIdentity(effectiveRecipeDigest: input.effectiveRecipe.digest(), working: working))
        }
    }
}

extension InputIdentityReuseTests {
    func testIdentityKeyPreservesAllEffectiveFieldsWithoutEncoding() throws {
        let base = EffectiveInputRecipe(declared: recipe, backendVersion: "backend")
        let key = InputIdentityKey(descriptor: descriptor, recipe: base)
        XCTAssertTrue(key.matches(descriptor: descriptor, recipe: base))
        var changed = base; changed.settings = [.init(key: .exposureEV, value: 0)]
        XCTAssertFalse(key.matches(descriptor: descriptor, recipe: changed))
        let zero = InputIdentityKey(descriptor: descriptor, recipe: changed)
        changed.settings[0].value = -0.0
        XCTAssertFalse(zero.matches(descriptor: descriptor, recipe: changed))
        changed = base; changed.backendVersion = "other"
        XCTAssertFalse(key.matches(descriptor: descriptor, recipe: changed))
        changed = base; changed.decoderVersion = "decoder"
        XCTAssertFalse(key.matches(descriptor: descriptor, recipe: changed))
        changed = base; changed.declared.rawSettings = [.init(key: .sharpness, value: 1, allowsUserOverride: true)]
        XCTAssertFalse(key.matches(descriptor: descriptor, recipe: changed))
        var a = descriptor; a.camera = "caf\u{e9}"
        var b = descriptor; b.camera = "cafe\u{301}"
        XCTAssertFalse(InputIdentityKey(descriptor: a, recipe: base).matches(descriptor: b, recipe: base))
    }
}
