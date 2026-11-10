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
    private func cornerLUT() -> LUTAsset {
        LUTAsset(name: "corner", cubeText: "LUT_3D_SIZE 2\n" + String(repeating: "0 0 0\n", count: 7) + "1 1 1")
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

    func testBoundedNonIdentityLUTMatchesFloat32OutsideCube() throws {
        let half = try RenderHarness(), full = try RenderHarness(precision: .float32)
        let lut = IndependentLUTTests.asset(0.5)
        let style = try ResolvedStyle(profile: .standard)
        var request = RenderRequest(input: .init(width: 2, height: 2))
        request.dynamicRange = .edr
        request.inputValueBounds = .init(lower: -0.25, upper: 4)
        for value: Float in [-0.25, 4] {
            let a = try half.encode(half.texture(width: 2, height: 2, value: value),
                                    half.encoder.prepare(style, lut: lut), request)
            let b = try full.encode(full.texture(width: 2, height: 2, value: value),
                                    full.encoder.prepare(style, lut: lut), request)
            XCTAssertEqual(a.pixelFormat, .rgba16Float)
            XCTAssertEqual(RenderHarness.read(a)[0], value * 0.5, accuracy: 0.005)
            for (actual, expected) in zip(RenderHarness.read(a), RenderHarness.read(b)) {
                XCTAssertEqual(actual, expected, accuracy: 0.005)
            }
        }
    }

    func testLargeAffineLUTRemainsSafeForBoundedEDR() throws {
        let h = try RenderHarness()
        let edge = 65
        var values = [Float]()
        values.reserveCapacity(edge * edge * edge * 3)
        for b in 0..<edge { for g in 0..<edge { for r in 0..<edge {
            values.append(contentsOf: [Float(r) / 128, Float(g) / 128, Float(b) / 128])
        } } }
        let lut = try LUTImporter.load(data: values.withUnsafeBytes { Data($0) },
                                       descriptor: .init(dimension: edge, layout: .rgbFloat32), name: "affine")
        let style = try h.encoder.prepare(ResolvedStyle(profile: .standard), lut: lut)
        var request = RenderRequest(input: .init(width: 2, height: 2))
        request.dynamicRange = .edr
        request.inputValueBounds = .init(lower: -0.25, upper: 6)
        XCTAssertEqual(try h.encoder.assessPrecision(style: style, request: request), .safe)
        let output = try h.encode(h.texture(width: 2, height: 2, value: 6), style, request)
        XCTAssertEqual(RenderHarness.read(output)[0], 3, accuracy: 0.005)
    }

    func testBoundedCorrectionLUTAfterColorTransform() throws {
        let h = try RenderHarness()
        let style = try h.encoder.prepare(ResolvedStyle(profile: .standard))
        let lut = IndependentLUTTests.asset(0.5)
        var correction = DeviceCorrection()
        correction.matrix.values = [2,0,0,0,2,0,0,0,2]
        var request = RenderRequest(input: .init(width: 2, height: 2))
        request.dynamicRange = .edr
        request.inputValueBounds = .init(lower: 2, upper: 2)
        let command = try XCTUnwrap(h.queue.makeCommandBuffer())
        let result = try h.encoder.encode(h.texture(width: 2, height: 2, value: 2), style: style,
            correction: h.encoder.prepareCorrection(correction, lut: lut), request: request, commandBuffer: command)
        let copy = try RenderHarness.ownedCopy(result, commandBuffer: command)
        command.commit(); command.waitUntilCompleted()
        XCTAssertNil(command.error)
        XCTAssertEqual(RenderHarness.read(copy)[0], Float(((2.0 + 0.055) * pow(2.0, 1 / 2.4) - 0.055) * 0.5), accuracy: 0.005)
    }

    func testWeightedCornerGrowthIsBoundedBeforeHalfStorage() throws {
        let h = try RenderHarness(), full = try RenderHarness(precision: .float32)
        var request = RenderRequest(input: .init(width: 2, height: 2))
        request.dynamicRange = .edr
        request.inputValueBounds = .init(lower: 50, upper: 50)
        let resolved = try ResolvedStyle(profile: .standard)
        let corner = cornerLUT()
        let output = try [h, full].map { harness in
            let base = try harness.encoder.prepare(resolved)
            let empty = try harness.encoder.prepare(resolved, lut: IndependentLUTTests.asset(0))
            let steep = try harness.encoder.prepare(resolved, lut: corner)
            let blend = try harness.encoder.blendStyle(base: base, styles: [steep, empty], weights: [1e-5, 1 - 1e-5])
            return RenderHarness.read(try harness.encode(harness.texture(width: 2, height: 2, value: 50), blend, request))[0]
        }
        XCTAssertEqual(output[0], 1.25, accuracy: 0.005)
        XCTAssertEqual(output[0], output[1], accuracy: 0.005)
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

    func testClampedLUTIsSafeForHalfAndRetainsClampSemantics() throws {
        let h = try RenderHarness()
        var asset = IndependentLUTTests.asset(0.5)
        asset.boundaryPolicy = .clamp
        let style = try h.encoder.prepare(ResolvedStyle(profile: .standard), lut: asset)
        var request = RenderRequest(input: .init(width: 2, height: 2))
        request.dynamicRange = .edr
        request.inputValueBounds = .init(lower: -0.25, upper: 4)
        XCTAssertEqual(try h.encoder.assessPrecision(style: style, request: request), .safe)
        let output = try h.encode(h.texture(width: 2, height: 2, value: 4), style, request)
        XCTAssertEqual(RenderHarness.read(output)[0], 0.5, accuracy: 0.005)
    }

    func testInputEditsCannotHideUnsafeSourceStorage() throws {
        let h = try RenderHarness()
        var profile = Profile.standard
        profile.parameters.color.exposureEV = -20
        let style = try h.encoder.prepare(ResolvedStyle(profile: profile))
        var request = RenderRequest(input: .init(width: 2, height: 2))
        request.dynamicRange = .edr
        request.inputValueBounds = .init(lower: 100_000, upper: 100_000)
        guard case .unsupported(.input, let reason) = try h.encoder.assessPrecision(style: style, request: request) else {
            return XCTFail("Expected rejection at source storage")
        }
        XCTAssertFalse(reason.isEmpty)
    }

    func testUnknownHalfInputRangeMatchesEncodingValidation() throws {
        let h = try RenderHarness(), full = try RenderHarness(precision: .float32)
        let resolved = try ResolvedStyle(profile: .standard)
        let style = try h.encoder.prepare(resolved, lut: IndependentLUTTests.asset(0.5))
        var request = RenderRequest(input: .init(width: 2, height: 2))
        request.dynamicRange = .edr
        XCTAssertEqual(try h.encoder.assessPrecision(style: style, request: request), .requiresInputRange)
        XCTAssertEqual(try full.encoder.assessPrecision(style: full.encoder.prepare(resolved), request: request), .safe)
        let command = try XCTUnwrap(h.queue.makeCommandBuffer())
        XCTAssertThrowsError(try h.encoder.encode(h.texture(width: 2, height: 2, value: 2), style: style,
                                                   request: request, commandBuffer: command))
        XCTAssertEqual(command.status, .notEnqueued)
    }

    func testMixedCornerGrowthRejectsAtTheFirstUnsafeStorageStage() throws {
        let h = try RenderHarness()
        let corner = cornerLUT()
        let style = try h.encoder.prepare(ResolvedStyle(profile: .standard), lut: corner)
        var request = RenderRequest(input: .init(width: 2, height: 2))
        request.dynamicRange = .edr
        // The continued trilinear function is r*g*b. 6³ fits the LUT output's
        // half texture but overflows the subsequent encoded-to-linear write.
        request.inputValueBounds = .init(lower: 6, upper: 6)
        guard case .unsupported(.linearOpticalInput, _) = try h.encoder.assessPrecision(style: style, request: request) else {
            return XCTFail("Expected rejection at linear optical input")
        }
        request.inputValueBounds = .init(lower: 50, upper: 50)
        guard case .unsupported(.creativeLUT, _) = try h.encoder.assessPrecision(style: style, request: request) else {
            return XCTFail("Expected rejection at LUT storage")
        }
        let command = try XCTUnwrap(h.queue.makeCommandBuffer())
        XCTAssertThrowsError(try h.encoder.encode(h.texture(width: 2, height: 2, value: 50), style: style,
                                                   request: request, commandBuffer: command))
        XCTAssertEqual(command.status, .notEnqueued)
        XCTAssertEqual(h.encoder.cachedTextureBytes, 0)
    }

    func testZeroWeightLUTDoesNotContributeToSafetyOrOutput() throws {
        let h = try RenderHarness()
        let resolved = try ResolvedStyle(profile: .standard)
        let corner = cornerLUT()
        let steep = try h.encoder.prepare(resolved, lut: corner)
        let flat = try h.encoder.prepare(resolved, lut: IndependentLUTTests.asset(0))
        let style = try h.encoder.blendStyle(base: h.encoder.prepare(resolved), styles: [steep, flat], weights: [0, 1])
        var request = RenderRequest(input: .init(width: 2, height: 2))
        request.dynamicRange = .edr
        request.inputValueBounds = .init(lower: 50, upper: 50)
        XCTAssertEqual(try h.encoder.assessPrecision(style: style, request: request), .safe)
        let output = try h.encode(h.texture(width: 2, height: 2, value: 50), style, request)
        XCTAssertEqual(RenderHarness.read(output)[0], 0)
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
