import XCTest
import CoreImage
import CoreVideo
import Metal
import ImageIO
import ImagingCore
@testable import ImageRendering

final class InputPreparationTests: XCTestCase {
    private func image(_ value: Float) -> CIImage {
        let values = [value, value, value, 1]
        return CIImage(bitmapData: values.withUnsafeBytes { Data($0) }, bytesPerRow: 16, size: CGSize(width: 1, height: 1), format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }
    private func pixel(_ input: PreparedInput) -> Float {
        var values = [Float](repeating: 0, count: 4)
        values.withUnsafeMutableBytes { CIContext().render(input.image, toBitmap: $0.baseAddress!, rowBytes: 16, bounds: input.image.extent, format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) }
        return values[0]
    }
    func testCalibrationAppliedExactlyOnce() async throws {
        let renderer = try LumeraRenderer()
        let working = WorkingImageContract(referenceRenditionID: "fixture")
        let adapter = try InputAdapter(renderer: renderer, working: working)
        var descriptor = SourceDescriptor(id: "fixture", path: .processedPhoto); descriptor.recipeID = "ci"
        let recipe = InputRecipe(id: "ci", backend: "coreImage", version: "1", decodedRendition: .baseImage)
        let execution = ExecutionProfile(width: 1, height: 1, budget: .init(maxInFlightFrames: 1, maxResidentBytes: 16 * 1024 * 1024))
        let normalized = try await adapter.prepare(.image(image(0.5)), descriptor: descriptor, recipe: recipe, execution: execution)
        var calibration = InputCalibration(id: "fixture", source: descriptor, working: working)
        calibration.recipeDigest = try normalized.effectiveRecipe.digest()
        calibration.correction.matrix.values = [0.5,0,0,0,0.5,0,0,0,0.5]
        let prepared = try await InputNormalizer(renderer: renderer).normalize(normalized, calibration: calibration, resources: ModelResourceSet())
        let linear = pow((0.5 + 0.055) / 1.055, 2.4)
        let expected = 1.055 * pow(linear * 0.5, 1 / 2.4) - 0.055
        XCTAssertEqual(Double(pixel(prepared)), expected, accuracy: 0.003)
        let twice = 1.055 * pow(linear * 0.25, 1 / 2.4) - 0.055
        XCTAssertGreaterThan(abs(Double(pixel(prepared)) - twice), 0.05)
        XCTAssertEqual(prepared.calibrationID, try calibration.digest())
        XCTAssertEqual(prepared.sourceID, normalized.sourceID)
    }
    func testRecipeChangeChangesInputIdentityAndRejectsOldCalibration() async throws {
        let renderer = try LumeraRenderer(), working = WorkingImageContract(referenceRenditionID: "fixture")
        let adapter = try InputAdapter(renderer: renderer, working: working)
        var descriptor = SourceDescriptor(id: "fixture", path: .processedPhoto); descriptor.recipeID = "ci"
        let execution = ExecutionProfile(width: 1, height: 1, budget: .init(maxInFlightFrames: 1, maxResidentBytes: 16 * 1024 * 1024))
        let first = try await adapter.prepare(.image(image(0.5)), descriptor: descriptor, recipe: .init(id: "ci", backend: "coreImage", version: "1", decodedRendition: .baseImage), execution: execution)
        let second = try await adapter.prepare(.image(image(0.5)), descriptor: descriptor, recipe: .init(id: "ci", backend: "coreImage", version: "2", decodedRendition: .baseImage), execution: execution)
        XCTAssertNotEqual(first.sourceID, second.sourceID)
        var calibration = InputCalibration(id: "fixture", source: descriptor, working: working)
        calibration.recipeDigest = try first.effectiveRecipe.digest()
        do { _ = try await InputNormalizer(renderer: renderer).normalize(second, calibration: calibration, resources: ModelResourceSet()); XCTFail("Old recipe qualification must fail") }
        catch { }
    }
    func testIdentityReferenceHasNoMeasuredQualificationAndPreservesFacts() async throws {
        let renderer = try LumeraRenderer(), working = WorkingImageContract(referenceRenditionID: "explicit-reference")
        let adapter = try InputAdapter(renderer: renderer, working: working)
        var descriptor = SourceDescriptor(id: "fixture", path: .processedPhoto); descriptor.recipeID = "ci"
        let source = image(0.5).settingProperties(["{Exif}": ["ISOSpeedRatings": [400], "ExposureTime": 0.01]])
        let execution = ExecutionProfile(width: 1, height: 1, budget: .init(maxInFlightFrames: 1, maxResidentBytes: 16 * 1024 * 1024))
        let normalized = try await adapter.prepare(.image(source), descriptor: descriptor, recipe: .init(id: "ci", backend: "coreImage", version: "1", decodedRendition: .baseImage), execution: execution)
        let prepared = try await InputNormalizer(renderer: renderer).normalize(normalized, calibration: nil, resources: ModelResourceSet())
        XCTAssertEqual(prepared.working.referenceRenditionID, "explicit-reference")
        XCTAssertTrue(prepared.qualifications.isEmpty)
        XCTAssertEqual(prepared.captureConditions.iso, 400)
        XCTAssertEqual(pixel(prepared), 0.5, accuracy: 0.003)
    }
    func testUnsupportedWorkingWhitePointAndScaleReject() throws {
        let renderer = try LumeraRenderer()
        var working = WorkingImageContract(referenceRenditionID: "fixture")
        working.referenceWhite = 2
        XCTAssertThrowsError(try InputAdapter(renderer: renderer, working: working))
        working.referenceWhite = 1; working.whitePoint = .init(x: 0.3457, y: 0.3585)
        XCTAssertThrowsError(try InputAdapter(renderer: renderer, working: working))
    }
    func testHalfBoundsContainStoredPixelsAndQualificationIsScoped() async throws {
        let renderer = try LumeraRenderer(), working = WorkingImageContract(referenceRenditionID: "fixture")
        let adapter = try InputAdapter(renderer: renderer, working: working)
        var descriptor = SourceDescriptor(id: "fixture", path: .processedPhoto); descriptor.recipeID = "ci"
        let execution = ExecutionProfile(width: 1, height: 1, budget: .init(maxInFlightFrames: 1, maxResidentBytes: 16 * 1024 * 1024))
        let normalized = try await adapter.prepare(.image(image(0.3)), descriptor: descriptor, recipe: .init(id: "ci", backend: "coreImage", version: "1", decodedRendition: .baseImage), execution: execution)
        let reference = try await InputNormalizer(renderer: renderer).normalize(normalized, calibration: nil, resources: ModelResourceSet())
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 1, height: 1, mipmapped: false)
        td.storageMode = .shared
        let copy = try XCTUnwrap(renderer.device.makeTexture(descriptor: td))
        let command = try XCTUnwrap(renderer.queue.makeCommandBuffer()), blit = try XCTUnwrap(command.makeBlitCommandEncoder())
        blit.copy(from: normalized.texture, to: copy); blit.endEncoding()
        try await renderer.complete(command)
        var storage = [Float16](repeating: 0, count: 4)
        storage.withUnsafeMutableBytes { copy.getBytes($0.baseAddress!, bytesPerRow: 8, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0) }
        XCTAssertTrue(reference.valueBounds.contains(Double(storage[0])), "Bounds must contain the actual stored component")
        var calibration = InputCalibration(id: "fixture", source: descriptor, working: working)
        calibration.recipeDigest = try normalized.effectiveRecipe.digest()
        calibration.qualifications = [.init(domain: .colorTone, evidenceDigest: String(repeating: "a", count: 64), conditionRanges: [.init(axis: .iso, bounds: .init(lower: 100, upper: 400))])]
        let prepared = try await InputNormalizer(renderer: renderer).normalize(normalized, calibration: calibration, resources: ModelResourceSet())
        XCTAssertTrue(prepared.qualifications.isEmpty, "Absent ISO cannot inherit measured coverage")
    }

    func testOrientationToneAndColorMetadataFollowActualPixels() async throws {
        let renderer = try LumeraRenderer(), working = WorkingImageContract(referenceRenditionID: "fixture")
        let adapter = try InputAdapter(renderer: renderer, working: working)
        var descriptor = SourceDescriptor(id: "fixture", path: .processedPhoto); descriptor.recipeID = "ci"
        let source = CIImage(color: .init(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: .init(x: 5, y: 8, width: 2, height: 3))
        let recipe = InputRecipe(id: "ci", backend: "coreImage", version: "1", decodedRendition: .baseImage)
        let execution = ExecutionProfile(width: 1, height: 1, budget: .init(maxInFlightFrames: 1, maxResidentBytes: 16 * 1024 * 1024))
        let normalized = try await adapter.prepare(.image(source, orientation: .right), descriptor: descriptor, recipe: recipe, execution: execution)
        XCTAssertEqual(normalized.width, 3); XCTAssertEqual(normalized.height, 2)
        XCTAssertEqual(normalized.image.extent.origin, .zero)
        XCTAssertEqual(normalized.image.properties[kCGImagePropertyOrientation as String] as? Int, 1)
        XCTAssertEqual(normalized.image.colorSpace?.name, CGColorSpace.sRGB)
        var calibration = InputCalibration(id: "fixture", source: descriptor, working: working)
        calibration.recipeDigest = try normalized.effectiveRecipe.digest()
        calibration.tone = ResponseCurve(knots: [.init(x: 0, y: 0), .init(x: 1, y: 0.5)], interpolation: .linear)
        let prepared = try await InputNormalizer(renderer: renderer).normalize(normalized, calibration: calibration, resources: ModelResourceSet())
        var values = [Float](repeating: 0, count: 24)
        values.withUnsafeMutableBytes { CIContext().render(prepared.image, toBitmap: $0.baseAddress!, rowBytes: 48, bounds: prepared.image.extent, format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) }
        XCTAssertEqual(values[0], 0.25, accuracy: 0.004)
    }
    func testDecodedImageRequiresRenditionChoice() async throws {
        let renderer = try LumeraRenderer(), working = WorkingImageContract(referenceRenditionID: "fixture")
        var descriptor = SourceDescriptor(id: "fixture", path: .processedPhoto); descriptor.recipeID = "ci"
        do {
            _ = try await InputAdapter(renderer: renderer, working: working).prepare(.image(image(0.5)), descriptor: descriptor,
                recipe: .init(id: "ci", backend: "coreImage", version: "1"), execution: .init(width: 1, height: 1, budget: .init(maxInFlightFrames: 1, maxResidentBytes: 16 * 1024 * 1024)))
            XCTFail("Implicit gain-map interpretation is not reproducible")
        } catch { }
    }

    func testUnqualifiedReferenceStillEnforcesWorkingBounds() async throws {
        let renderer = try LumeraRenderer()
        var working = WorkingImageContract(referenceRenditionID: "fixture"); working.dynamicRange = .edr
        let adapter = try InputAdapter(renderer: renderer, working: working)
        var descriptor = SourceDescriptor(id: "fixture", path: .processedPhoto); descriptor.recipeID = "ci"
        var execution = ExecutionProfile(width: 1, height: 1, budget: .init(maxInFlightFrames: 1, maxResidentBytes: 16 * 1024 * 1024)); execution.dynamicRange = .edr
        let values: [Float] = [4,4,4,1]
        let hdr = CIImage(bitmapData: values.withUnsafeBytes { Data($0) }, bytesPerRow: 16, size: .init(width: 1, height: 1), format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedSRGB))
        let normalized = try await adapter.prepare(.image(hdr), descriptor: descriptor, recipe: .init(id: "ci", backend: "coreImage", version: "1", decodedRendition: .baseImage), execution: execution)
        do { _ = try await InputNormalizer(renderer: renderer).normalize(normalized, calibration: nil, resources: .init()); XCTFail("EDR pixels cannot claim a 0...1 working domain") } catch { }
    }
    func testNonpropagatingCaptureFactsRemainAvailableWithoutExportingAttachments() async throws {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 1, 1, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        let input = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(input, [])
        memset(CVPixelBufferGetBaseAddress(input), 255, CVPixelBufferGetDataSize(input))
        CVPixelBufferUnlockBaseAddress(input, [])
        CVBufferSetAttachment(input, "{Exif}" as CFString, ["ISOSpeedRatings": [800]] as CFDictionary, .shouldNotPropagate)
        let renderer = try LumeraRenderer()
        var descriptor = SourceDescriptor(id: "fixture", path: .videoYUV); descriptor.recipeID = "ci"
        let normalized = try await InputAdapter(renderer: renderer, working: .init(referenceRenditionID: "fixture")).prepare(.pixelBuffer(input), descriptor: descriptor,
            recipe: .init(id: "ci", backend: "coreImage", version: "1"), execution: .init(width: 1, height: 1, budget: .init(maxInFlightFrames: 1, maxResidentBytes: 16 * 1024 * 1024)))
        XCTAssertEqual(normalized.captureConditions.iso, 800)
        XCTAssertNil((normalized.image.properties["{Exif}"] as? [String: Any])?["ISOSpeedRatings"])
    }

}

extension InputPreparationTests {
    func testTrustedNormalizedRangeChecksActualStoredPixels() async throws {
        let renderer = try LumeraRenderer()
        var working = WorkingImageContract(referenceRenditionID: "fixture"); working.dynamicRange = .edr
        let adapter = try InputAdapter(renderer: renderer, working: working)
        var execution = ExecutionProfile(width: 1, height: 1,
            budget: .init(maxInFlightFrames: 1, maxResidentBytes: 16 * 1024 * 1024))
        execution.dynamicRange = .edr
        var descriptor = SourceDescriptor(id: "fixture", path: .processedPhoto); descriptor.recipeID = "ci"
        let recipe = InputRecipe(id: "ci", backend: "coreImage", version: "1", decodedRendition: .baseImage)
        let result = try await adapter.prepare(.image(image(0.5)), descriptor: descriptor, recipe: recipe, execution: execution,
            trustedNormalizedRGBBounds: .init(lower: 0.4, upper: 0.6))
        let unknown = try await adapter.prepare(.image(image(0.5)), descriptor: descriptor, recipe: recipe, execution: execution)
        XCTAssertEqual(result.valueBounds, unknown.valueBounds)
        XCTAssertEqual(result.valueBounds.lower, 0.5, accuracy: 0.003)
        XCTAssertEqual(result.valueBounds.upper, 0.5, accuracy: 0.003)
        for bounds in [NumericBounds(lower: 0.8, upper: 1), .init(lower: 0, upper: 65_500)] {
            do {
                _ = try await adapter.prepare(.image(image(0.5)), descriptor: descriptor, recipe: recipe, execution: execution,
                    trustedNormalizedRGBBounds: bounds)
                XCTFail("Accepted invalid trusted bounds or out-of-bounds stored pixels")
            } catch { }
        }
    }
}
