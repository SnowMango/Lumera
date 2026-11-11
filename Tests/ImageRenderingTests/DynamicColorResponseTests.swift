import XCTest
import CoreImage
import Metal
import ImagingCore
@testable import ImageRendering

final class DynamicColorResponseTests: XCTestCase {
    func execution(_ precision: ExecutionPrecision) -> ExecutionProfile {
        var e = ExecutionProfile(width: 2, height: 2, budget: .init(maxInFlightFrames: 1, maxResidentBytes: 64 * 1024 * 1024)); e.precision = precision; return e
    }
    func input(_ renderer: LumeraRenderer, _ precision: ExecutionPrecision) async throws -> PreparedInput {
        let image = CIImage(color: .init(red: 0.4, green: 0.5, blue: 0.6)).cropped(to: .init(x: 0, y: 0, width: 2, height: 2))
        var source = SourceDescriptor(id: "fixture", path: .processedPhoto); source.recipeID = "ci"
        let normalized = try await InputAdapter(renderer: renderer, working: .init(referenceRenditionID: "fixture")).prepare(.image(image), descriptor: source, recipe: .init(id: "ci", backend: "coreImage", version: "1", decodedRendition: .baseImage), execution: execution(precision))
        return try await InputNormalizer(renderer: renderer).normalize(normalized, calibration: nil, resources: .init())
    }
    func cube(_ gain: Double = 1, warp: Double = 0) -> LUTAsset {
        var lines = ["LUT_3D_SIZE 3"]
        for b in 0..<3 { for g in 0..<3 { for r in 0..<3 {
            lines.append([r,g,b].map { String(Double($0)/2 * gain + ($0 == 1 ? warp : 0)) }.joined(separator: " "))
        } } }
        return .init(name: "fixture", cubeText: lines.joined(separator: "\n"))
    }
    func model(_ assets: [String: LUTAsset] = [:]) -> StyleModel {
        var m = StyleModel(identity: .init(id: "dynamic", name: "synthetic"))
        m.appearance.resources = assets.keys.sorted().map { .init(id: $0, sha256: assets[$0]!.sha256, dimension: 3) }; return m
    }
    func curve(_ gain: Double) -> ResponseCurve { .init(knots: (0..<32).map { .init(x: Double($0)/31, y: Double($0)/31 * gain) }) }
    func render(_ renderer: LumeraRenderer, input: PreparedInput, model: PreparedStyleModel, position: Double = 0.5, edits: EditRequest = .init(), region: CGRect? = nil, sampleRegion: CGRect? = nil) async throws -> [Float] {
        let stamp = FrameStamp(streamID: "fixture", generation: 1, index: 0, presentationTime: 0, duration: 1)
        let observations = FrameObservations(stamp: stamp, sourceID: input.sourceID, calibrationID: input.calibrationID, featureDigest: model.compiled.featureDigest)
        var conditions = CaptureConditions(); conditions.exposureBiasEV = position; conditions.iso = 200
        let automatic = try StyleModelEvaluator.evaluate(model.compiled, context: .init(evaluationStamp: stamp, observations: observations, targetConditions: conditions))
        let controls = try EditResolver.resolve(edits, automatic: automatic, model: model.compiled)
        let plan = try RenderPlanner().plan(controls, input: input, model: model)
        let output: RenderedFrame
        if let region { output = try await renderer.renderTiled(input, plan: plan, region: region) }
        else {
            let command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
            let encoded = try FrameEncoder(renderer: renderer).encode(input, plan: plan, commandBuffer: command)
            let ticket = try encoded.copyOwned(commandBuffer: command); try await renderer.complete(command)
            output = try ticket.resolve()
        }
        // Bitmap rows are top-first; crop the full result to the same CI-coordinate
        // ROI before comparing a region, rather than comparing opposite image rows.
        let image = sampleRegion.map { output.image.cropped(to: $0) } ?? output.image
        var pixels = [Float](repeating: 0, count: 16)
        pixels.withUnsafeMutableBytes { CIContext().render(image, toBitmap: $0.baseAddress!, rowBytes: 32, bounds: image.extent, format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) }
        return Array(pixels.prefix(3))
    }
    func testDynamicMatrixThenCurveChangesPixelsInBothPrecisions() async throws {
        for precision: ExecutionPrecision in [.float16, .float32] {
            let renderer = try LumeraRenderer(precision: precision == .float16 ? .float16 : .float32), input = try await input(renderer, precision)
            var m = model(); m.appearance.parameters.tone.enabled = true
            let matrix = { (gain: Double) in ColorMatrix3x3(values: [gain,0,0,0,gain,0,0,0,gain]) }
            m.responses = [.init(target: "color.matrix", expression: .singleAxis(axis: .target(.exposureBiasEV), nodes: [.init(0, .matrix(matrix(0.5))), .init(1, .matrix(matrix(1)))], boundary: .clamp)), .init(target: "tone.curve", expression: .singleAxis(axis: .target(.exposureBiasEV), nodes: [.init(0, .curve(curve(0.5))), .init(1, .curve(curve(1)))], boundary: .clamp))]
            let prepared = try ModelPreparer(renderer: renderer).prepare(StyleModelCompiler.compile(m), resources: .init(), execution: execution(precision))
            let pixels = try await render(renderer, input: input, model: prepared)
            for (pixel, source) in zip(pixels, [0.4,0.5,0.6]) {
                let linear = pow((source + 0.055)/1.055, 2.4)
                let expected = (1.055 * pow(linear * 0.75, 1/2.4) - 0.055) * 0.75
                XCTAssertEqual(Double(pixel), expected, accuracy: precision == .float16 ? 0.003 : 0.00002)
            }
        }
    }
    func testTwoAxisLUTPixelsAndResidentUploadsAreReused() async throws {
        for precision: ExecutionPrecision in [.float16, .float32] {
            let renderer = try LumeraRenderer(precision: precision == .float16 ? .float16 : .float32), input = try await input(renderer, precision)
            let assets = ["a": cube(0.25), "b": cube(0.5), "c": cube(0.75), "d": cube(1)]
            var m = model(assets)
            m.responses = [.init(target: "style.lutWeights", expression: .twoAxisGrid(xAxis: .target(.exposureBiasEV), yAxis: .target(.iso), x: [0,1], y: [100,400], values: ["a","b","c","d"].map { .resourceWeights([.init(resourceID: $0, weight: 1)]) }, boundary: .clamp))]
            let prepared = try ModelPreparer(renderer: renderer).prepare(StyleModelCompiler.compile(m), resources: .init(luts: assets), execution: execution(precision))
            let before = renderer.encoder.staticResourceStatistics
            for position in [0.0, 0.5, 1.0, 0.5] {
                let pixels = try await render(renderer, input: input, model: prepared, position: position)
                let gain = 0.5 + position * 0.25
                for (pixel, source) in zip(pixels, [0.4,0.5,0.6]) { XCTAssertEqual(Double(pixel), source * gain, accuracy: precision == .float16 ? 0.003 : 0.00002) }
            }
            XCTAssertEqual(renderer.encoder.staticResourceStatistics.lutUploads, before.lutUploads)
            XCTAssertEqual(renderer.encoder.staticResourceStatistics.lutParses, before.lutParses)
        }
    }
    func testNeutralStrengthVerifiesWeightedIdentityRatherThanEachLUT() async throws {
        let renderer = try LumeraRenderer(), input = try await input(renderer, .float16)
        let assets = ["a": cube(warp: 0.125), "b": cube(warp: -0.125)]
        var m = model(assets); m.appearance.lutWeights = [.init(resourceID: "a", weight: 1)]
        m.edits.strength = .init(neutralParameters: .init(), neutralLUTWeights: [.init(resourceID: "a", weight: 0.5), .init(resourceID: "b", weight: 0.5)])
        let prepared = try ModelPreparer(renderer: renderer).prepare(StyleModelCompiler.compile(m), resources: .init(luts: assets), execution: execution(.float16))
        var edits = EditRequest(); edits.strength = 0
        let pixels = try await render(renderer, input: input, model: prepared, edits: edits)
        for (pixel, expected) in zip(pixels, [0.4,0.5,0.6]) { XCTAssertEqual(Double(pixel), expected, accuracy: 0.003) }
    }
    func testDeclaredBoundsAndUnsafeHalfExtrapolationReject() async throws {
        let renderer = try LumeraRenderer(), input = try await input(renderer, .float16)
        let assets = ["a": cube(0.5), "b": cube(0.75)]
        var m = model(assets); m.appearance.lutWeights = [.init(resourceID: "a", weight: 0.5), .init(resourceID: "b", weight: 0.5)]
        m.appearance.resources[0].outputBounds = .init(lower: 0, upper: 0.1)
        XCTAssertThrowsError(try ModelPreparer(renderer: renderer).prepare(StyleModelCompiler.compile(m), resources: .init(luts: assets), execution: execution(.float16)))
        m = model(assets); m.appearance.lutWeights = [.init(resourceID: "a", weight: 0.5), .init(resourceID: "b", weight: 0.5)]
        for i in m.appearance.resources.indices { m.appearance.resources[i].outOfRange = .linearExtrapolation }
        let prepared = try ModelPreparer(renderer: renderer).prepare(StyleModelCompiler.compile(m), resources: .init(luts: assets), execution: execution(.float16))
        do { _ = try await render(renderer, input: input, model: prepared); XCTFail("Unsafe half LUT extrapolation must reject") } catch { }
    }
    func testNonneutralMixtureAndUnprovenExtendedNeutralReject() throws {
        let renderer = try LumeraRenderer()
        let assets = ["a": cube(warp: 0.125), "b": cube(warp: -0.125)]
        var m = model(assets); m.appearance.lutWeights = [.init(resourceID: "a", weight: 1)]
        m.edits.strength = .init(neutralParameters: .init(), neutralLUTWeights: [.init(resourceID: "a", weight: 0.75), .init(resourceID: "b", weight: 0.25)])
        XCTAssertThrowsError(try ModelPreparer(renderer: renderer).prepare(StyleModelCompiler.compile(m), resources: .init(luts: assets), execution: execution(.float16)))
        m.edits.strength!.neutralLUTWeights = [.init(resourceID: "a", weight: 0.5), .init(resourceID: "b", weight: 0.5)]
        m.compatibility.dynamicRanges = [.sdr, .edr]
        var extended = execution(.float16); extended.dynamicRange = .edr
        XCTAssertThrowsError(try ModelPreparer(renderer: renderer).prepare(StyleModelCompiler.compile(m), resources: .init(luts: assets), execution: extended))
    }
    func testWeightedLUTRegionUsesSameFullFrameGeometry() async throws {
        for precision: ExecutionPrecision in [.float16, .float32] {
            let renderer = try LumeraRenderer(precision: precision == .float16 ? .float16 : .float32), input = try await input(renderer, precision)
            let assets = ["a": cube(0.5), "b": cube(1)]
            var m = model(assets); m.appearance.lutWeights = [.init(resourceID: "a", weight: 0.5), .init(resourceID: "b", weight: 0.5)]
            m.appearance.parameters.vignette.enabled = true; m.appearance.parameters.vignette.amountEV = 1
            m.appearance.parameters.vignette.centerX = 0; m.appearance.parameters.vignette.centerY = 0
            let prepared = try ModelPreparer(renderer: renderer).prepare(StyleModelCompiler.compile(m), resources: .init(luts: assets), execution: execution(precision))
            let whole = try await render(renderer, input: input, model: prepared, sampleRegion: .init(x: 0, y: 0, width: 1, height: 1))
            let region = try await render(renderer, input: input, model: prepared, region: .init(x: 0, y: 0, width: 1, height: 1))
            for (a,b) in zip(whole, region) { XCTAssertEqual(a, b, accuracy: precision == .float16 ? 0.003 : 0.00002) }
        }
    }

    func testNearIdentityNeutralGridDoesNotQualifyForExtendedExtrapolation() throws {
        let renderer = try LumeraRenderer(precision: .float32)
        let assets = ["a": cube(warp: 0.125), "b": cube(warp: -0.125 + 1e-7)]
        var m = model(assets); m.compatibility.dynamicRanges = [.edr]
        m.appearance.lutWeights = [.init(resourceID: "a", weight: 1)]
        for i in m.appearance.resources.indices { m.appearance.resources[i].outOfRange = .linearExtrapolation }
        m.edits.strength = .init(neutralParameters: .init(), neutralLUTWeights: [.init(resourceID: "a", weight: 0.5), .init(resourceID: "b", weight: 0.5)])
        var e = execution(.float32); e.dynamicRange = .edr
        XCTAssertThrowsError(try ModelPreparer(renderer: renderer).prepare(StyleModelCompiler.compile(m), resources: .init(luts: assets), execution: e))
    }
    func testPreparationBudgetIncludesLargestDecodeWorkspace() throws {
        let renderer = try LumeraRenderer(precision: .float32), asset = cube()
        var m = model(["a": asset]); m.appearance.lutWeights = [.init(resourceID: "a", weight: 1)]
        let texture = MTLTextureDescriptor(); texture.textureType = .type3D; texture.pixelFormat = .rgba32Float
        texture.width = 3; texture.height = 3; texture.depth = 3; texture.storageMode = .shared; texture.usage = .shaderRead
        let persistent = renderer.device.heapTextureSizeAndAlign(descriptor: texture).size + asset.cubeText.utf8.count + 3*3*3*16
        var e = execution(.float32); e.budget.maxResidentBytes = persistent + 2*2*16*4
        XCTAssertThrowsError(try ModelPreparer(renderer: renderer).prepare(StyleModelCompiler.compile(m), resources: .init(luts: ["a": asset]), execution: e))
    }

}
