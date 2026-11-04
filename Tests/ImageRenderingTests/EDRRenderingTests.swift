import XCTest
import CoreImage
import CoreVideo
import ImageIO
import Metal
import ImagingCore
@testable import ImageRendering

final class EDRRenderingTests: XCTestCase {
    // Decoding also exercises compatibility: older implementations ignore this setting,
    // so these tests fail on pixel values rather than failing to compile.
    private func edrOptions() throws -> RenderOptions {
        let data = try JSON.encode(RenderOptions())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["dynamicRange"] = "edr"
        return try JSONDecoder().decode(RenderOptions.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testIdentityLUTPreservesSignedExtendedValuesAndSDRStillClamps() throws {
        let h = try RenderHarness(precision: .float32)
        let style = try h.encoder.prepare(ResolvedStyle(profile: .standard), lut: IndependentLUTTests.asset(1))
        for value: Float in [-0.25, 0, 0.5, 1, 2, 4] {
            let input = try h.texture(width: 2, height: 2, value: value)
            let edr = try edrOptions().makeRequest(input: .init(width: 2, height: 2))
            let output = RenderHarness.read(try h.encode(input, style, edr))
            XCTAssertEqual(output[0], value, accuracy: 0.0001)
            XCTAssertEqual(output[3], 1)
            let sdr = RenderRequest(input: .init(width: 2, height: 2))
            XCTAssertEqual(RenderHarness.read(try h.encode(input, style, sdr))[0], min(1, max(0, value)), accuracy: 0.0001)
        }
    }

    func testAffineLUTExtrapolatesMultipleChannelsAndCorrection() throws {
        let h = try RenderHarness(precision: .float32)
        // Hand-derived transform: R=.5R+.25G, G=.5G+.1, B=.5B.
        var lines = ["LUT_3D_SIZE 2"]
        for b in 0...1 { for g in 0...1 { for r in 0...1 {
            lines.append("\(Double(r)*0.5+Double(g)*0.25) \(Double(g)*0.5+0.1) \(Double(b)*0.5)")
        } } }
        let lut = LUTAsset(name: "affine", cubeText: lines.joined(separator: "\n"))
        let input = try h.texture(width: 1, height: 1)
        let samples: [Float] = [2, -0.4, 3, 1]
        samples.withUnsafeBytes { input.replace(region: MTLRegionMake2D(0,0,1,1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 16) }
        let request = try edrOptions().makeRequest(input: .init(width: 1, height: 1))
        let style = try h.encoder.prepare(ResolvedStyle(profile: .standard), lut: lut)
        let actual = RenderHarness.read(try h.encode(input, style, request))
        for (a, b) in zip(actual, [Float(0.9), -0.1, 1.5, 1]) { XCTAssertEqual(a, b, accuracy: 0.0001) }
        let correction = try h.encoder.prepareCorrection(nil, lut: lut)
        let command = try XCTUnwrap(h.queue.makeCommandBuffer())
        let neutral = try h.encoder.prepare(ResolvedStyle(profile: .standard))
        let corrected = try h.encoder.encode(input, style: neutral, correction: correction, request: request, commandBuffer: command)
        command.commit(); command.waitUntilCompleted()
        XCTAssertNil(command.error)
        for (a, b) in zip(RenderHarness.read(corrected), actual) { XCTAssertEqual(a, b, accuracy: 0.0001) }
    }

    func testToneKeepsHighlightDifferencesBeyondItsDefinedRange() throws {
        let h = try RenderHarness(precision: .float32)
        var profile = Profile.standard
        profile.parameters.tone.enabled = true
        profile.parameters.tone.curve = .init(knots: [.init(x: 0, y: 0.1), .init(x: 1, y: 0.8)])
        let style = try h.encoder.prepare(ResolvedStyle(profile: profile))
        let request = try edrOptions().makeRequest(input: .init(width: 2, height: 2))
        for (value, expected): (Float, Float) in [(-0.2, -0.1), (0.5, 0.45), (2, 1.8), (4, 3.8)] {
            let actual = RenderHarness.read(try h.encode(h.texture(width: 2, height: 2, value: value), style, request))
            XCTAssertEqual(actual[0], expected, accuracy: 0.0001)
        }
    }

    func testCIImagePreservesEDRAndOutputColorSpace() async throws {
        let renderer = try LumeraRenderer(precision: .float32)
        let style = try renderer.prepare(.standard, lut: IndependentLUTTests.asset(0.5))
        let output = try await renderer.render(image([2, -0.2, 0.5, 1]), style: style, options: edrOptions())
        for (a, b) in zip(pixels(output).prefix(4), [Float(1), -0.1, 0.25, 1]) { XCTAssertEqual(a, b, accuracy: 0.002) }
        XCTAssertEqual(output.colorSpace?.name, CGColorSpace.extendedSRGB)
        let exif = try XCTUnwrap(output.properties[kCGImagePropertyExifDictionary as String] as? [String: Any])
        XCTAssertEqual(exif[kCGImagePropertyExifColorSpace as String] as? Int, 65535)
    }

    func testEDRTiledAndRegionMatchFullFrame() async throws {
        let renderer = try LumeraRenderer(precision: .float32)
        let style = try renderer.prepare(.standard, lut: IndependentLUTTests.asset(0.75))
        var options = try edrOptions(); options.maximumLongEdge = 8
        let input = image([2, -0.2, 0.5, 1], width: 12, height: 8)
        let full = try await renderer.render(input, style: style, options: options)
        let tiled = try await renderer.renderTiled(input, style: style, options: options)
        let region = try await renderer.renderRegion(input, region: CGRect(x: 1, y: 1, width: 2, height: 2), style: style, options: options)
        XCTAssertEqual(tiled.colorSpace?.name, CGColorSpace.extendedSRGB)
        for result in [full, tiled, region] {
            for (a, b) in zip(pixels(result).prefix(4), [Float(1.5), -0.15, 0.375, 1]) { XCTAssertEqual(a, b, accuracy: 0.003) }
        }
    }

    func testEDRPixelBufferStaysFloatAndCanBeRenderedAgain() async throws {
        let renderer = try LumeraRenderer(precision: .float32)
        let style = try renderer.prepare(.standard, lut: IndependentLUTTests.asset(1))
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 4, 4, kCVPixelFormatType_128RGBAFloat,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let input = try XCTUnwrap(buffer), space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedSRGB))
        CIContext().render(image([2, -0.2, 0.5, 1]), to: input, bounds: CGRect(x:0,y:0,width:4,height:4), colorSpace: space)
        CVBufferSetAttachment(input, kCVImageBufferCGColorSpaceKey, space, .shouldPropagate)
        let output = try await renderer.render(input, style: style, options: edrOptions())
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(output), kCVPixelFormatType_128RGBAFloat)
        let again = try await renderer.render(output, style: style, options: edrOptions())
        for (a, b) in zip(pixels(CIImage(cvPixelBuffer: again)).prefix(4), [Float(2), -0.2, 0.5, 1]) { XCTAssertEqual(a, b, accuracy: 0.003) }
    }

    func testRangeChangesRenderIdentity() throws {
        let style = try ResolvedStyle(profile: .standard)
        let sdr = RenderRequest(input: .init(width: 4, height: 4))
        let edr = try edrOptions().makeRequest(input: sdr.input)
        XCTAssertNotEqual(try RenderIdentity.make(style: style, request: sdr, precision: .float32),
                          try RenderIdentity.make(style: style, request: edr, precision: .float32))
    }

    func testNoiseAndGrainDoNotClipExtendedColors() throws {
        let h = try RenderHarness(precision: .float32)
        let request = try edrOptions().makeRequest(input: .init(width: 8, height: 8))
        for grain in [false, true] {
            var profile = Profile.standard
            if grain {
                profile.parameters.grain.enabled = true
                profile.parameters.grain.amount = 0.01
                profile.parameters.grain.luminanceCurve = .init(function: .init(family: .constant, start: 1, end: 1))
            } else {
                profile.parameters.noise.enabled = true
                profile.parameters.noise.curve = .init(function: .init(family: .constant, start: 0.01, end: 0.01))
            }
            let style = try h.encoder.prepare(ResolvedStyle(profile: profile))
            for value: Float in [-0.5, 2] {
                let values = RenderHarness.read(try h.encode(h.texture(width: 8, height: 8, value: value), style, request))
                let rgb = values.enumerated().filter { $0.offset % 4 != 3 }.map(\.element)
                XCTAssertTrue(rgb.allSatisfy(\.isFinite))
                XCTAssertEqual(rgb.reduce(0,+) / Float(rgb.count), value, accuracy: 0.08)
            }
        }
    }

    func testBoundaryPolicyOverridesAndCacheIdentity() throws {
        let h = try RenderHarness(precision: .float32)
        let style = try ResolvedStyle(profile: .standard)
        let input = try h.texture(width: 2, height: 2, value: 3)
        let request = try edrOptions().makeRequest(input: .init(width: 2, height: 2))
        var lut = IndependentLUTTests.asset(0.5)
        let originalDigest = lut.sha256
        let inferred = try h.encoder.prepare(style, lut: lut)
        let automaticIdentity = try RenderIdentity.make(style: style, resources: .init(lut: lut), request: request, precision: .float32)
        lut.boundaryPolicy = .clamp
        let bounded = try h.encoder.prepare(style, lut: lut)
        XCTAssertEqual(lut.sha256, originalDigest)
        XCTAssertNotEqual(automaticIdentity, try RenderIdentity.make(style: style, resources: .init(lut: lut), request: request, precision: .float32))
        XCTAssertEqual(RenderHarness.read(try h.encode(input, inferred, request))[0], 1.5, accuracy: 0.0001)
        XCTAssertEqual(RenderHarness.read(try h.encode(input, bounded, request))[0], 0.5, accuracy: 0.0001)
        XCTAssertEqual(RenderHarness.read(try h.encode(input, inferred, request))[0], 1.5, accuracy: 0.0001)

        var identity = IndependentLUTTests.asset(1); identity.boundaryPolicy = .clamp
        let correction = try XCTUnwrap(h.encoder.prepareCorrection(nil, lut: identity))
        let command = try XCTUnwrap(h.queue.makeCommandBuffer())
        let result = try h.encoder.encode(input, style: h.encoder.prepare(style), correction: correction,
                                         request: request, commandBuffer: command)
        command.commit(); command.waitUntilCompleted(); XCTAssertNil(command.error)
        XCTAssertEqual(RenderHarness.read(result)[0], 1, accuracy: 0.0001)
    }

    func testExplicitExtrapolationAlsoWorksWithSDROutput() throws {
        let h = try RenderHarness(precision: .float32)
        var lut = IndependentLUTTests.asset(0.25); lut.boundaryPolicy = .extrapolate
        let style = try h.encoder.prepare(ResolvedStyle(profile: .standard), lut: lut)
        let input = try h.texture(width: 2, height: 2, value: 2)
        let request = RenderRequest(input: .init(width: 2, height: 2))
        XCTAssertEqual(RenderHarness.read(try h.encode(input, style, request))[0], 0.5, accuracy: 0.0001)
    }

    func testExtrapolationUsesNearestBoundaryCellOfLargerCube() throws {
        let h = try RenderHarness(precision: .float32)
        var lines = ["LUT_3D_SIZE 3"]
        for b in 0...2 { for g in 0...2 { for r in 0...2 {
            lines.append("\(Double(r*r)/4) \(Double(g*g)/4) \(Double(b*b)/4)")
        } } }
        let lut = LUTAsset(name: "squared", cubeText: lines.joined(separator: "\n"))
        let style = try h.encoder.prepare(ResolvedStyle(profile: .standard), lut: lut)
        let request = try edrOptions().makeRequest(input: .init(width: 2, height: 2))
        for (value, expected): (Float, Float) in [(-0.25, -0.125), (0.25, 0.125), (1, 1), (2, 2.5)] {
            XCTAssertEqual(RenderHarness.read(try h.encode(h.texture(width: 2, height: 2, value: value), style, request))[0], expected, accuracy: 0.0001)
        }
    }

    func testEDROpticsAndDefaultPrecisionRetainBrightValues() throws {
        let h = try RenderHarness()
        var profile = Profile.standard
        profile.parameters.softening.enabled = true; profile.parameters.softening.amount = 0.5
        profile.parameters.vignette.enabled = true; profile.parameters.vignette.amountEV = 1
        profile.parameters.glow.enabled = true; profile.parameters.glow.amount = 0.1
        let style = try h.encoder.prepare(ResolvedStyle(profile: profile))
        let request = try edrOptions().makeRequest(input: .init(width: 8, height: 8))
        let result = try h.encode(h.texture(width: 8, height: 8, value: 4), style, request)
        let values = RenderHarness.read(result)
        XCTAssertTrue(values.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(values[0], 1)
        XCTAssertGreaterThan(values[(4*8+4)*4], values[0])
        let unorm = try h.texture(width: 8, height: 8, format: .rgba8Unorm)
        XCTAssertThrowsError(try h.encode(unorm, style, request))
    }

    func testExplicitSDRExtrapolationDoesNotOverflowHalfBeforeColorTransform() throws {
        let h = try RenderHarness() // Default precision must promote the extrapolating path.
        var samples = [Float](repeating: 0, count: 64*64*64*3)
        for i in (samples.count-3)..<samples.count { samples[i] = 1 }
        var lut = try LUTImporter.load(data: samples.withUnsafeBytes { Data($0) },
            descriptor: .init(dimension: 64, layout: .rgbFloat32), name: "corner")
        lut.boundaryPolicy = .extrapolate
        var correction = DeviceCorrection(); correction.matrix.values = [4,0,0,0,4,0,0,0,4]
        var profile = Profile.standard; profile.parameters.color.matrix.values = [1e-13,0,0,0,1e-13,0,0,0,1e-13]
        let fixed = try h.encoder.prepareCorrection(correction, lut: lut)
        let style = try h.encoder.prepare(ResolvedStyle(profile: profile))
        let command = try XCTUnwrap(h.queue.makeCommandBuffer())
        let output = try h.encoder.encode(h.texture(width: 2, height: 2, value: 1), style: style, correction: fixed,
            request: .init(input: .init(width: 2, height: 2)), commandBuffer: command)
        command.commit(); command.waitUntilCompleted(); XCTAssertNil(command.error)
        // Analytic fixture: E(4)=1.824796; boundary weight=52.962167; cube=148558.4.
        // Decode, scale linear RGB by 1e-13, encode -> 0.514155.
        let values = RenderHarness.read(output)
        XCTAssertTrue(values.allSatisfy(\.isFinite))
        XCTAssertEqual(values[0], 0.514155, accuracy: 0.002)
    }

    func testNonAffineCubeContinuesAcrossMultichannelCorner() throws {
        let h = try RenderHarness(precision: .float32)
        var lines = ["LUT_3D_SIZE 2"]
        for b in 0...1 { for g in 0...1 { for r in 0...1 {
            lines.append("\(r*g) \(g*b) \(b*r)")
        } } }
        let style = try h.encoder.prepare(ResolvedStyle(profile: .standard), lut: .init(name: "products", cubeText: lines.joined(separator: "\n")))
        let input = try h.texture(width: 1, height: 1)
        let values: [Float] = [2, -0.5, 3, 1]
        values.withUnsafeBytes { input.replace(region: MTLRegionMake2D(0,0,1,1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 16) }
        let result = RenderHarness.read(try h.encode(input, style, edrOptions().makeRequest(input: .init(width: 1, height: 1))))
        for (actual, expected) in zip(result, [Float(-1), -1.5, 6, 1]) { XCTAssertEqual(actual, expected, accuracy: 0.0001) }
    }

    func testDynamicFramesAlternateRangesWithoutReusingWrongNoisePrecision() throws {
        let h = try RenderHarness()
        var profile = Profile.standard
        profile.parameters.noise.enabled = true
        profile.parameters.noise.curve = .init(function: .init(family: .constant, start: 0.01, end: 0.01))
        let definition = try StyleEvaluator.compile(profile)
        let style = try h.encoder.prepare(definition, lut: IndependentLUTTests.asset(0.5))
        let frame = try FrameStyleParameters(StyleEvaluator.evaluate(definition))
        let input = try h.texture(width: 8, height: 8, value: 3)
        var first: [Float] = []
        for (index, range) in [RenderDynamicRange.edr, .sdr, .edr].enumerated() {
            var request = RenderRequest(input: .init(width: 8, height: 8)); request.dynamicRange = range
            let command = try XCTUnwrap(h.queue.makeCommandBuffer())
            let output = try h.encoder.encode(input, style: style, parameters: frame, request: request, commandBuffer: command)
            command.commit(); command.waitUntilCompleted(); XCTAssertNil(command.error)
            let result = RenderHarness.read(output)
            if index == 0 { first = result; XCTAssertGreaterThan(result[0], 1) }
            if index == 1 { XCTAssertLessThan(result[0], 1) }
            if index == 2 { XCTAssertEqual(result, first) }
        }
        XCTAssertEqual(h.encoder.staticResourceStatistics.lutUploads, 1)
    }

    func testLinearEDRInputIsEncodedOnceAndKnownHeadroomDoesNotToneMap() async throws {
        let renderer = try LumeraRenderer(), style = try renderer.prepare(.standard)
        let samples: [Float] = [4, 0.25, -0.25, 1]
        var input = CIImage(bitmapData: samples.withUnsafeBytes { Data($0) }, bytesPerRow: 16,
            size: CGSize(width: 1, height: 1), format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        if #available(iOS 26, macOS 26, *) { input = input.settingContentHeadroom(4) }
        let output = try await renderer.render(input, style: style, options: edrOptions())
        for (actual, expected) in zip(pixels(output), [Float(1.824796), 0.537099, -0.537099, 1]) {
            XCTAssertEqual(actual, expected, accuracy: 0.002)
        }
        if #available(iOS 18, macOS 15, *) { XCTAssertEqual(output.contentHeadroom, 0) }
    }

    private func image(_ sample: [Float], width: Int = 4, height: Int = 4) -> CIImage {
        let values = Array(repeating: sample, count: width*height).flatMap { $0 }
        return CIImage(bitmapData: values.withUnsafeBytes { Data($0) }, bytesPerRow: width*16,
            size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedSRGB))
    }
    private func pixels(_ image: CIImage) -> [Float] {
        var result = [Float](repeating: 0, count: Int(image.extent.width*image.extent.height)*4)
        result.withUnsafeMutableBytes { CIContext().render(image, toBitmap: $0.baseAddress!, rowBytes: Int(image.extent.width)*16,
            bounds: image.extent, format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedSRGB)) }
        return result
    }
}
