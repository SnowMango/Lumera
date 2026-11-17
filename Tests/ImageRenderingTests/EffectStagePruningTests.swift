import XCTest
import Metal
import ImagingCore
@testable import ImageRendering

final class EffectStagePruningTests: XCTestCase {
    // At this long edge the default blur radii all require both separable passes.
    private let width = 2048, height = 8

    private func pixels() -> [Float] {
        (0..<(width * height * 4)).map { $0 % 4 == 3 ? 1 : 0.5 }
    }

    private func render(_ session: ReferenceRenderSession, _ parameters: StyleParameters,
                        pixels: [Float], lut: LUTAsset? = nil, previewGlow: Bool = true) throws -> [Float] {
        let style = try ResolvedStyle(parameters: parameters, profileDigest: "stage-test", temporalPolicy: .init())
        var request = RenderRequest(input: .init(width: width, height: height))
        request.previewGlow = previewGlow
        return try session.withRenderedTexture(pixels: pixels, style: style, correction: nil,
            resources: .init(lut: lut), request: request) { texture, command in
                command.commit(); command.waitUntilCompleted()
                XCTAssertNil(command.error)
                return RenderHarness.read(texture)
            }
    }

    func testSharpeningDoesNotDispatchNeutralDetailOrReserveItsHalo() throws {
        let session = try ReferenceRenderSession(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        var p = StyleParameters(); p.detail.enabled = true; p.detail.sharpenAmount = 0.5
        let result = try render(session, p, pixels: pixels())
        // Two sharpen blur passes, sharpen, and encoded output normalization.
        XCTAssertEqual(session.lastWork.dispatches, 4)
        XCTAssertEqual(result[0], 0.5, accuracy: 1e-6)
        let planner = try TilePlanner(width: width, height: height, style: p, options: .init(),
            budget: 16 * 1024 * 1024, preparedGrain: nil)
        XCTAssertEqual(planner.halo, 3)

        p.detail.fineGain = 1.2
        _ = try render(session, p, pixels: pixels())
        XCTAssertEqual(session.lastWork.dispatches, 9, "Non-neutral detail still precedes sharpening")
        let combined = try TilePlanner(width: width, height: height, style: p, options: .init(),
            budget: 16 * 1024 * 1024, preparedGrain: nil)
        XCTAssertEqual(combined.halo, 11)

        p.detail.sharpenAmount = 0
        _ = try render(session, p, pixels: pixels())
        XCTAssertEqual(session.lastWork.dispatches, 6)
        p.detail.enabled = false
        _ = try render(session, p, pixels: pixels())
        XCTAssertEqual(session.lastWork.dispatches, 0)
    }

    func testColorAndLUTOnlyNeedTheirOwnPassAndOutputNormalization() throws {
        let session = try ReferenceRenderSession(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        var p = StyleParameters(); p.color.exposureEV = 1
        _ = try render(session, p, pixels: pixels())
        XCTAssertEqual(session.lastWork.dispatches, 2)
        let output = try render(session, .init(), pixels: pixels(), lut: IndependentLUTTests.asset(0.5))
        XCTAssertEqual(session.lastWork.dispatches, 2)
        XCTAssertEqual(output[0], 0.25, accuracy: 1e-6)

        p.glow.enabled = true; p.glow.amount = 0.5
        p.halation.enabled = true; p.halation.amount = 0.5
        _ = try render(session, p, pixels: pixels(), previewGlow: false)
        XCTAssertEqual(session.lastWork.dispatches, 2)
    }

    func testEncodedSuffixPreservesRangeAndNormalizesAlpha() throws {
        for precision in [RenderingPrecision.float16, .float32] {
            let h = try RenderHarness(precision: precision)
            let input = try h.texture(width: 4, height: 4)
            let pixel: [Float] = [-0.25, 0.5, 2, 0.25]
            let data = Array(repeating: pixel, count: 16).flatMap { $0 }
            data.withUnsafeBytes { input.replace(region: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0,
                withBytes: $0.baseAddress!, bytesPerRow: 4 * 16) }
            for extended in [false, true] {
                let p = StyleParameters(), color = try ColorTransform.prepare(p.color)
                let geometry = RenderGeometry(fullWidth: 4, fullHeight: 4, area: CGRect(x: 0, y: 0, width: 4, height: 4),
                    sourceWidth: 4, sourceHeight: 4, sourceArea: CGRect(x: 0, y: 0, width: 4, height: 4))
                var request = RenderRequest(input: .init(width: 4, height: 4))
                request.dynamicRange = extended ? .edr : .sdr
                let command = try XCTUnwrap(h.queue.makeCommandBuffer())
                let arena = Arena(device: h.device)
                arena.configure(width: 4, height: 4, limit: nil, format: precision == .float16 ? .rgba16Float : .rgba32Float)
                let backend = RealtimeEffectBackend(arena: arena, pipelines: h.encoder.pipelines,
                    commandBuffer: command, geometry: nil, frameGeometry: geometry)
                let frame = EffectFrame(executionPlan: try PreparedExecutionPlan(parameters: p, color: color),
                    parameters: p, color: color, curves: PreparedResponseCurves(p), lut: nil, lutBoundaryPolicy: .automatic,
                    correction: nil, temporal: .init(), request: request, geometry: geometry)
                let output = try EffectPipeline(backend: backend, frame: frame).encodeSuffix(input)
                command.commit(); command.waitUntilCompleted(); XCTAssertNil(command.error)
                let expected: [Float] = extended ? [-0.25, 0.5, 2, 1] : [0, 0.5, 1, 1]
                XCTAssertEqual(Array(RenderHarness.read(output).prefix(4)), expected)
            }
        }
    }

    func testReferencePrefixCacheTracksOpticalDomainWithNoiseAndGrain() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let session = try ReferenceRenderSession(device: device)
        let data = pixels()
        var p = StyleParameters(); p.color.exposureEV = 0.2
        p.noise.enabled = true; p.noise.curve = .init(function: .init(family: .constant, start: 0.02, end: 0.02))
        p.grain.enabled = true; p.grain.amount = 0.01
        for optical in [false, true, false] {
            p.vignette.enabled = optical; p.vignette.amountEV = 1
            let fresh = try render(ReferenceRenderSession(device: device), p, pixels: data)
            let first = try render(session, p, pixels: data)
            XCTAssertEqual(session.lastWork.prefixHits, 0)
            let cached = try render(session, p, pixels: data)
            XCTAssertEqual(session.lastWork.prefixHits, 1)
            XCTAssertEqual(first, fresh); XCTAssertEqual(cached, fresh)
        }
    }

    func testHalfPrecisionDoesNotRejectAnUnusedLinearIntermediate() throws {
        let h = try RenderHarness()
        var p = Profile.standard; p.parameters.detail.enabled = true; p.parameters.detail.sharpenAmount = 0.1
        let style = try h.encoder.prepare(ResolvedStyle(profile: p))
        var request = RenderRequest(input: .init(width: 2048, height: 8))
        request.dynamicRange = .edr; request.inputValueBounds = .init(lower: 0, upper: 1000)
        // Encoded 1000 fits half. Its decoded linear value does not fit a half texture.
        if case .safe = try h.encoder.assessPrecision(style: style, request: request) {} else {
            XCTFail("An absent linear stage must not reject encoded-range sharpening")
        }
        p.parameters.vignette.enabled = true; p.parameters.vignette.amountEV = 1
        let optical = try h.encoder.prepare(ResolvedStyle(profile: p))
        if case .unsupported = try h.encoder.assessPrecision(style: optical, request: request) {} else {
            XCTFail("Real optical work still requires a representable linear intermediate")
        }
    }

    func testOptimizedStagesStayWithinRoundingErrorOfFormerSequence() throws {
        // Retain the former pass sequence here as an independent GPU regression oracle.
        // Nonconstant RGB exposes detail/sharpen changes that flat-field checks cannot.
        for precision in [RenderingPrecision.float16, .float32] {
            let h = try RenderHarness(precision: precision)
            for extended in [false, true] {
                let input = try h.texture(width: width, height: height)
                var data = [Float]()
                for y in 0..<height { for x in 0..<width {
                    let r = Float((x * 17 + y * 3) % 257) / 256
                    let g = Float((x * 5 + y * 31) % 131) / 130
                    let b = Float((x * 11 + y * 7) % 193) / 192
                    data += extended ? [r * 4.25 - 0.25, g * 4.25 - 0.25, b * 4.25 - 0.25, 1] : [r, g, b, 1]
                } }
                data.withUnsafeBytes { input.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                    withBytes: $0.baseAddress!, bytesPerRow: width * 16) }
                for sharpening in [false, true] {
                    var p = StyleParameters()
                    if sharpening { p.detail.enabled = true; p.detail.sharpenAmount = 0.5 }
                    else { p.color.exposureEV = 0.2 }
                    let color = try ColorTransform.prepare(p.color)
                    var request = RenderRequest(input: .init(width: width, height: height))
                    request.dynamicRange = extended ? .edr : .sdr
                    request.inputValueBounds = .init(lower: extended ? -0.25 : 0, upper: extended ? 4 : 1)
                    let style = try h.encoder.prepare(ResolvedStyle(parameters: p, profileDigest: "rounding", temporalPolicy: .init()))
                    let optimized = RenderHarness.read(try h.encode(input, style, request))

                    let command = try XCTUnwrap(h.queue.makeCommandBuffer()), arena = Arena(device: h.device)
                    arena.configure(width: width, height: height, limit: nil, format: precision == .float16 ? .rgba16Float : .rgba32Float)
                    let geometry = RenderGeometry(fullWidth: width, fullHeight: height,
                        area: CGRect(x: 0, y: 0, width: width, height: height), sourceWidth: width, sourceHeight: height,
                        sourceArea: CGRect(x: 0, y: 0, width: width, height: height))
                    let backend = RealtimeEffectBackend(arena: arena, pipelines: h.encoder.pipelines,
                        commandBuffer: command, geometry: nil, frameGeometry: geometry)
                    var current = input
                    if sharpening {
                        let fine = try backend.blur(current, p.detail.fineSigma), mid = try backend.blur(current, p.detail.midSigma)
                        current = try backend.pass("detailCombine", current, [fine, mid], [1, 1])
                        let blurred = try backend.blur(current, p.detail.sharpenSigma)
                        current = try backend.pass("sharpen", current, [blurred], [0.5, 0.008, 0.015])
                    } else { current = try backend.pass("colorResponse", current, [], color.uniforms) }
                    current = try backend.pass("transfer", current, [], [-1])
                    let old = try backend.pass(extended ? "finishExtended" : "finish", current, [current, current], EffectUniforms.noise(p.noise))
                    command.commit(); command.waitUntilCompleted(); XCTAssertNil(command.error)
                    let original = RenderHarness.read(old)
                    let maximum = zip(optimized, original).map { abs($0 - $1) }.max()!
                    // Half EDR reaches just above 4 after sharpening, where one
                    // storage ULP is 1/256; allow two such steps across removed writes.
                    let tolerance: Float = precision == .float16 ? (extended ? 0.008 : 0.0015) : 0.00001
                    XCTAssertLessThanOrEqual(maximum, tolerance,
                        "precision=\(precision), extended=\(extended), sharpening=\(sharpening)")
                }
            }
        }
    }
}
