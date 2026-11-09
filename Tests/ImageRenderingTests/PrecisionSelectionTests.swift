import XCTest
import CoreImage
import CoreVideo
import ImageIO
import Metal
import ImagingCore
@testable import ImageRendering

final class PrecisionSelectionTests: XCTestCase {
    private func options() -> RenderOptions { var options = RenderOptions(); options.dynamicRange = .edr; return options }
    private func image(_ value: Float) -> CIImage {
        let values = [value, value, value, 1]
        return CIImage(bitmapData: values.withUnsafeBytes { Data($0) }, bytesPerRow: 16,
                       size: CGSize(width: 1, height: 1), format: .RGBAf,
                       colorSpace: CGColorSpace(name: CGColorSpace.extendedSRGB))
    }
    private func pixel(_ image: CIImage) -> Float {
        var values = [Float](repeating: 0, count: 4)
        values.withUnsafeMutableBytes {
            CIContext().render(image, toBitmap: $0.baseAddress!, rowBytes: 16,
                               bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf,
                               colorSpace: CGColorSpace(name: CGColorSpace.extendedSRGB))
        }
        return values[0]
    }
    func testEDRDefaultIsFloat16AndExplicitFloat32IsRespected() async throws {
        for precision in [RenderingPrecision.float16, .float32] {
            let renderer = try LumeraRenderer(precision: precision)
            let style = try renderer.prepare(.standard)
            for value: Float in [-0.25, 0, 0.5, 1, 2, 4] {
                let output = try await renderer.render(image(value), style: style, options: options())
                XCTAssertEqual(output.properties[kCGImagePropertyDepth as String] as? Int, precision == .float16 ? 16 : 32)
                XCTAssertEqual(pixel(output), value, accuracy: 0.005)
            }
        }
    }
    func testRegionAndTileUseSelectedPrecision() async throws {
        let renderer = try LumeraRenderer()
        var profile = Profile.standard
        profile.parameters.glow.enabled = true; profile.parameters.glow.amount = 0.1
        let style = try renderer.prepare(profile)
        let input = image(4).transformed(by: CGAffineTransform(scaleX: 4, y: 4))
        let region = try await renderer.renderRegion(input, region: CGRect(x: 1, y: 1, width: 1, height: 1), style: style, options: options())
        let tiled = try await renderer.renderTiled(input, style: style, options: options())
        for output in [region, tiled] {
            XCTAssertEqual(output.properties[kCGImagePropertyDepth as String] as? Int, 16)
            XCTAssertGreaterThan(pixel(output), 1)
            XCTAssertTrue(pixel(output).isFinite)
        }
    }
    func testEDRPixelBufferFormatMatchesPrecision() async throws {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 1, 1, kCVPixelFormatType_128RGBAFloat,
                                         [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let input = try XCTUnwrap(buffer)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedSRGB))
        CIContext().render(image(4), to: input, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), colorSpace: space)
        CVBufferSetAttachment(input, kCVImageBufferCGColorSpaceKey, space, .shouldPropagate)
        for precision in [RenderingPrecision.float16, .float32] {
            let renderer = try LumeraRenderer(precision: precision)
            let output = try await renderer.render(input, style: renderer.prepare(.standard), options: options())
            XCTAssertEqual(CVPixelBufferGetPixelFormatType(output), precision == .float16 ? kCVPixelFormatType_64RGBAHalf : kCVPixelFormatType_128RGBAFloat)
            XCTAssertEqual(pixel(CIImage(cvPixelBuffer: output)), 4, accuracy: 0.005)
        }
    }
    func testUnknownCIExtremeRangeRejectsInsteadOfOverflowingHalf() async throws {
        let renderer = try LumeraRenderer()
        do {
            _ = try await renderer.render(image(100_000), style: renderer.prepare(.standard), options: options())
            XCTFail("Expected explicit Float16 rejection")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Float32")) }
    }
    func testUnsafeHalfPrecisionRejectsBeforeOutputPublication() throws {
        let h = try RenderHarness()
        var samples = [Float](repeating: 0, count: 64 * 64 * 64 * 3)
        for i in (samples.count - 3)..<samples.count { samples[i] = 1 }
        var lut = try LUTImporter.load(data: samples.withUnsafeBytes { Data($0) }, descriptor: .init(dimension: 64, layout: .rgbFloat32), name: "corner")
        lut.boundaryPolicy = .extrapolate
        var correction = DeviceCorrection(); correction.matrix.values = [4,0,0,0,4,0,0,0,4]
        var profile = Profile.standard; profile.parameters.color.matrix.values = [1e-13,0,0,0,1e-13,0,0,0,1e-13]
        let command = try XCTUnwrap(h.queue.makeCommandBuffer())
        XCTAssertThrowsError(try h.encoder.encode(h.texture(width: 2, height: 2, value: 1),
            style: h.encoder.prepare(ResolvedStyle(profile: profile)), correction: h.encoder.prepareCorrection(correction, lut: lut),
            request: .init(input: .init(width: 2, height: 2)), commandBuffer: command)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Float32"))
        }
        XCTAssertEqual(command.status, .notEnqueued)
        XCTAssertEqual(h.encoder.cachedTextureBytes, 0)
    }

    func testInputRangeReadbackRequiresCompletionAndRejectsNonfiniteValues() throws {
        let h = try RenderHarness(), reducer = try InputRangeReducer(device: h.device)
        for value: Float in [4, .nan, .infinity] {
            let command = try XCTUnwrap(h.queue.makeCommandBuffer())
            let readback = try reducer.encode(h.texture(width: 17, height: 9, value: value), commandBuffer: command)
            XCTAssertThrowsError(try readback.resolve())
            command.commit(); command.waitUntilCompleted(); XCTAssertNil(command.error)
            if value.isFinite { XCTAssertEqual(try readback.resolve(), .init(lower: 4, upper: 4)) }
            else { XCTAssertThrowsError(try readback.resolve()) }
        }
    }

    func testClampedModelLUTIsSafeForHalf() throws {
        var asset = IndependentLUTTests.asset(0.5); asset.boundaryPolicy = .clamp
        let weights = [ResourceWeight(resourceID: "look", weight: 1)]
        let automatic = AutomaticControls(parameters: .init(), lutWeights: weights, modelID: "model", sourceID: "source", calibrationID: "calibration", featureDigest: "features")
        let controls = ResolvedControls(automatic: automatic, parameters: automatic.parameters, lutWeights: weights)
        XCTAssertNoThrow(try PrecisionSafety.validate(inputBounds: -0.25...4, controls: controls,
            resources: ModelResourceSet(luts: ["look": asset]), precision: .float16, dynamicRange: .edr, scale: 1, resizing: false))
    }

    func testInputEditsCannotHideUnsafeSourceStorage() throws {
        var parameters = StyleParameters(); parameters.color.exposureEV = -20
        let automatic = AutomaticControls(parameters: parameters, modelID: "model", sourceID: "source", calibrationID: "calibration", featureDigest: "features")
        let controls = ResolvedControls(automatic: automatic, parameters: parameters, lutWeights: [], inputExposureEV: -10)
        XCTAssertThrowsError(try PrecisionSafety.validate(inputBounds: 100000...100000, controls: controls,
            resources: ModelResourceSet(), precision: .float16, dynamicRange: .edr, scale: 1, resizing: false))
    }

    func testPrecisionChoiceKeepsNoiseStorageAndIdentitySeparate() throws {
        let half = try RenderHarness(), full = try RenderHarness(precision: .float32)
        var profile = Profile.standard
        profile.parameters.noise.enabled = true
        profile.parameters.noise.curve = .init(function: .init(family: .constant, start: 0.01, end: 0.01))
        let resolved = try ResolvedStyle(profile: profile)
        var request = RenderRequest(input: .init(width: 8, height: 8))
        request.dynamicRange = .edr; request.inputValueBounds = .init(lower: 0, upper: 4)
        let halfStyle = try half.encoder.prepare(resolved), fullStyle = try full.encoder.prepare(resolved)
        let first = try half.encode(half.texture(width: 8, height: 8, value: 2), halfStyle, request)
        let second = try full.encode(full.texture(width: 8, height: 8, value: 2), fullStyle, request)
        let repeated = try half.encode(half.texture(width: 8, height: 8, value: 2), halfStyle, request)
        XCTAssertEqual(first.pixelFormat, .rgba16Float)
        XCTAssertEqual(second.pixelFormat, .rgba32Float)
        XCTAssertEqual(RenderHarness.read(first), RenderHarness.read(repeated))
        for (a, b) in zip(RenderHarness.read(first), RenderHarness.read(second)) { XCTAssertEqual(a, b, accuracy: 0.005) }
        XCTAssertNotEqual(try RenderIdentity.make(style: resolved, request: request, precision: .float16),
                          try RenderIdentity.make(style: resolved, request: request, precision: .float32))
    }

    func testIdentityReusesOnlyMatchingPrecisionStorage() throws {
        let half = try RenderHarness(), full = try RenderHarness(precision: .float32)
        let source = try half.texture(width: 8, height: 8, value: 0.5)
        let request = RenderRequest(input: .init(width: 8, height: 8))
        let halfStyle = try half.encoder.prepare(ResolvedStyle(profile: .standard))
        let converted = try half.encode(source, halfStyle, request)
        XCTAssertFalse(converted === source)
        XCTAssertEqual(converted.pixelFormat, .rgba16Float)
        XCTAssertEqual(RenderHarness.read(converted), RenderHarness.read(source))
        XCTAssertTrue(try half.encode(converted, halfStyle, request) === converted)
        XCTAssertTrue(try full.encode(source, full.encoder.prepare(ResolvedStyle(profile: .standard)), request) === source)
    }

}
