import XCTest
import CoreImage
import CoreVideo
import Metal
import ImagingCore
@testable import ImageRendering
@testable import ImagingRuntime

final class PhotoProcessorTests: XCTestCase {
    var working: WorkingImageContract { .init(referenceRenditionID: "fixture") }
    var recipe: InputRecipe { .init(id: "ci", backend: "coreImage", version: "1", decodedRendition: .baseImage) }
    var descriptor: SourceDescriptor { var d = SourceDescriptor(id: "input", path: .processedPhoto); d.recipeID = "ci"; return d }
    var execution: ExecutionProfile { .init(width: 4, height: 4, budget: .init(maxInFlightFrames: 1, maxResidentBytes: 64 * 1024 * 1024)) }
    var stamp: FrameStamp { .init(streamID: "photo", generation: 0, index: 17, presentationTime: 1.7, duration: 0.1) }
    func image(_ value: Float = 0.5, width: Int = 4, height: Int = 4) -> CIImage {
        let pixels: [Float] = (0..<(width * height)).flatMap { _ in [value,value,value,1] }
        return CIImage(bitmapData: pixels.withUnsafeBytes { Data($0) }, bytesPerRow: width * 16, size: .init(width: width, height: height), format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }
    func pixels(_ image: CIImage) -> [Float] {
        let width = Int(image.extent.width), height = Int(image.extent.height)
        var output = [Float](repeating: 0, count: width * height * 4)
        output.withUnsafeMutableBytes { CIContext().render(image, toBitmap: $0.baseAddress!, rowBytes: width * 16, bounds: image.extent, format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) }
        return output
    }
    func definition() -> StyleModel {
        var m = StyleModel(identity: .init(id: "synthetic", name: "manual"))
        m.compatibility.referenceRenditionIDs = [working.referenceRenditionID]
        m.edits.overrideTargets = ["color.exposureEV"]
        return m
    }
    func testDefaultPhotoUsesOneCalibrationAndOriginalObservation() async throws {
        let renderer = try LumeraRenderer(), processor = try PhotoProcessor(renderer: renderer, working: working)
        var m = definition(); m.observations.features = [.init(id: "mean", statistic: .meanRed)]
        let model = try ModelPreparer(renderer: renderer).prepare(StyleModelCompiler.compile(m), resources: .init(), execution: execution)
        let normalized = try await InputAdapter(renderer: renderer, working: working).prepare(.image(image()), descriptor: descriptor, recipe: recipe, execution: execution)
        var calibration = InputCalibration(id: "half", source: descriptor, working: working)
        calibration.recipeDigest = try normalized.effectiveRecipe.digest(); calibration.correction.matrix.values = [0.5,0,0,0,0.5,0,0,0,0.5]
        let result = try await processor.process(.image(image()), descriptor: descriptor, recipe: recipe, calibration: calibration, model: model, stamp: stamp)
        let linear = pow((0.5 + 0.055) / 1.055, 2.4) * 0.5
        XCTAssertEqual(Double(pixels(result.frame.image)[0]), 1.055 * pow(linear, 1 / 2.4) - 0.055, accuracy: 0.003)
        XCTAssertEqual(result.snapshot.observations.features[0].value!, linear, accuracy: 0.001)
        XCTAssertEqual(result.frame.stamp, stamp)
        var edits = EditRequest(); edits.overrides = [.init(target: "color.exposureEV", value: .scalar(1))]
        _ = try await processor.render(result.snapshot, edits: edits, execution: execution)
        XCTAssertEqual(result.snapshot.observations, result.decision.observations)
        XCTAssertEqual(result.snapshot.automatic.parameters.color.exposureEV, 0)
    }
    func testRegionTilesAndExportReuseDecision() async throws {
        let renderer = try LumeraRenderer(), processor = try PhotoProcessor(renderer: renderer, working: working)
        var m = definition(); m.appearance.parameters.vignette.enabled = true; m.appearance.parameters.vignette.amountEV = 1
        m.appearance.parameters.vignette.centerX = 0.2; m.appearance.parameters.vignette.centerY = 0.8
        let model = try ModelPreparer(renderer: renderer).prepare(StyleModelCompiler.compile(m), resources: .init(), execution: execution)
        let result = try await processor.process(.image(image()), descriptor: descriptor, recipe: recipe, calibration: nil, model: model, stamp: stamp)
        let region = CGRect(x: 1, y: 1, width: 2, height: 3)
        let cropped = try await processor.render(result.snapshot, region: region, execution: execution)
        let expected = result.frame.image.cropped(to: region).transformed(by: .init(translationX: -region.minX, y: -region.minY))
        for (a,b) in zip(pixels(cropped.image), pixels(expected)) { XCTAssertEqual(a,b,accuracy:0.003) }
        XCTAssertEqual(cropped.region, region); XCTAssertEqual(cropped.stamp, stamp)
        let tiled = try await processor.render(result.snapshot, execution: execution, tiled: true)
        for (a,b) in zip(pixels(tiled.image), pixels(result.frame.image)) { XCTAssertEqual(a,b,accuracy:0.003) }
    }
    func testFloat32ExportRepreparesOriginalPixels() async throws {
        let renderer = try LumeraRenderer(), processor = try PhotoProcessor(renderer: renderer, working: working)
        let model = try ModelPreparer(renderer: renderer).prepare(StyleModelCompiler.compile(definition()), resources: .init(), execution: execution)
        let source: Float = 0.30001
        let result = try await processor.process(.image(image(source)), descriptor: descriptor, recipe: recipe, calibration: nil, model: model, stamp: stamp)
        var high = execution; high.precision = .float32
        let exported = try await processor.render(result.snapshot, execution: high)
        XCTAssertEqual(exported.texture?.pixelFormat, .rgba32Float)
        XCTAssertNotEqual(exported.inputID, result.snapshot.input.inputID)
        let halfError = abs(pixels(result.frame.image)[0] - source), fullError = abs(pixels(exported.image)[0] - source)
        XCTAssertLessThan(fullError, halfError * 0.5)
        XCTAssertLessThan(fullError, 0.00001)
    }
    func testForeignSnapshotAndChangedFileReject() async throws {
        let renderer = try LumeraRenderer(), first = try PhotoProcessor(renderer: renderer, working: working), second = try PhotoProcessor(renderer: renderer, working: working)
        let model = try ModelPreparer(renderer: renderer).prepare(StyleModelCompiler.compile(definition()), resources: .init(), execution: execution)
        let result = try await first.process(.image(image()), descriptor: descriptor, recipe: recipe, calibration: nil, model: model, stamp: stamp)
        do { _ = try await second.render(result.snapshot, execution: execution); XCTFail("Foreign snapshot accepted") } catch { }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("first".utf8).write(to: url)
        let lease = try PhotoSourceLease(.rawURL(url))
        try Data("other".utf8).write(to: url)
        XCTAssertThrowsError(try lease.validate())
    }
    func testCapturePathAndInputCropCreateNewDecisions() async throws {
        let renderer = try LumeraRenderer(), processor = try PhotoProcessor(renderer: renderer, working: working)
        var m = definition(); m.observations.sourceConditions = [.iso]
        m.responses = [.init(target: "color.exposureEV", expression: .singleAxis(axis: .source(.iso), nodes: [.init(100,.scalar(0)),.init(400,.scalar(1))], boundary: .clamp))]
        let compiled = try StyleModelCompiler.compile(m)
        let model = try ModelPreparer(renderer: renderer).prepare(compiled, resources: .init(), execution: execution)
        let first = try await processor.process(.image(image(), metadata: ["{Exif}": ["ISOSpeedRatings": [100]]]), descriptor: descriptor, recipe: recipe, calibration: nil, model: model, stamp: stamp)
        var buffer: CVPixelBuffer?; XCTAssertEqual(CVPixelBufferCreate(nil, 4, 4, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        let video = try XCTUnwrap(buffer); CVPixelBufferLockBaseAddress(video, [])
        memset(CVPixelBufferGetBaseAddress(video), 128, CVPixelBufferGetDataSize(video)); CVPixelBufferUnlockBaseAddress(video, [])
        var videoDescriptor = descriptor; videoDescriptor.path = .videoYUV
        let second = try await processor.process(.pixelBuffer(video, metadata: ["{Exif}": ["ISOSpeedRatings": [400]]]), descriptor: videoDescriptor, recipe: recipe, calibration: nil, model: model, stamp: stamp)
        XCTAssertNotEqual(first.snapshot.input.sourceID, second.snapshot.input.sourceID)
        XCTAssertEqual(first.snapshot.automatic.parameters.color.exposureEV, 0)
        XCTAssertEqual(second.snapshot.automatic.parameters.color.exposureEV, 1)
        var small = execution; small.width = 2; small.height = 2
        let croppedModel = try ModelPreparer(renderer: renderer).prepare(compiled, resources: .init(), execution: small)
        let cropped = try await processor.process(.image(image(0.2, width: 2, height: 2), metadata: ["{Exif}": ["ISOSpeedRatings": [100]]]), descriptor: descriptor, recipe: recipe, calibration: nil, model: croppedModel, stamp: stamp)
        XCTAssertNotEqual(cropped.snapshot.input.inputID, first.snapshot.input.inputID)
        XCTAssertEqual(cropped.snapshot.input.width, 2)
    }
    func testPrecisionVariantSharesActiveFrameLimit() async throws {
        let renderer = try LumeraRenderer(), processor = try PhotoProcessor(renderer: renderer, working: working)
        let model = try ModelPreparer(renderer: renderer).prepare(StyleModelCompiler.compile(definition()), resources: .init(), execution: execution)
        let result = try await processor.process(.image(image()), descriptor: descriptor, recipe: recipe, calibration: nil, model: model, stamp: stamp)
        let occupied = try model.reserveFrame()
        defer { occupied.cancel() }
        var high = execution; high.precision = .float32
        do {
            _ = try await processor.render(result.snapshot, execution: high)
            XCTFail("Precision variant bypassed the active frame limit")
        } catch { }
    }
    func testSnapshotCannotReplaceItsBudget() async throws {
        let renderer = try LumeraRenderer(), processor = try PhotoProcessor(renderer: renderer, working: working)
        let model = try ModelPreparer(renderer: renderer).prepare(StyleModelCompiler.compile(definition()), resources: .init(), execution: execution)
        let result = try await processor.process(.image(image()), descriptor: descriptor, recipe: recipe, calibration: nil, model: model, stamp: stamp)
        var changed = execution; changed.budget.maxResidentBytes *= 2
        do {
            _ = try await processor.render(result.snapshot, execution: changed)
            XCTFail("Snapshot replaced its shared memory budget")
        } catch { }
    }

    func testSnapshotCachesCompleteExecutionVariants() async throws {
        let renderer = try LumeraRenderer(), processor = try PhotoProcessor(renderer: renderer, working: working)
        let model = try ModelPreparer(renderer: renderer).prepare(StyleModelCompiler.compile(definition()), resources: .init(), execution: execution)
        let result = try await processor.process(.image(image()), descriptor: descriptor, recipe: recipe, calibration: nil, model: model, stamp: stamp)
        var high = execution; high.precision = .float32
        let first = try result.snapshot.executionVariant(high)
        let repeated = try result.snapshot.executionVariant(high)
        XCTAssertTrue(first.model === repeated.model)
        XCTAssertTrue(first.renderer === repeated.renderer)
        var reduced = high; reduced.width = 2; reduced.height = 2
        let smaller = try result.snapshot.executionVariant(reduced)
        XCTAssertFalse(first.model === smaller.model)
        let occupied = try first.model.reserveFrame(); defer { occupied.cancel() }
        XCTAssertThrowsError(try smaller.model.reserveFrame())
        XCTAssertThrowsError(try model.reserveFrame())
    }
    func testVariantResourceReservationAndRelease() throws {
        let renderer = try LumeraRenderer()
        let asset = LUTAsset(name: "identity", cubeText: "LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1")
        var definition = definition()
        definition.appearance.resources = [.init(id: "lut", sha256: asset.sha256, dimension: 2)]
        definition.appearance.lutWeights = [.init(resourceID: "lut", weight: 1)]
        let model = try ModelPreparer(renderer: renderer).prepare(StyleModelCompiler.compile(definition), resources: .init(luts: ["lut": asset]), execution: execution)
        func allowance() throws -> Int {
            let reservation = try model.reserveFrame(); defer { reservation.cancel() }
            return reservation.execution.budget.maxResidentBytes
        }
        let originalAllowance = try allowance()
        var smaller = execution; smaller.width = 2; smaller.height = 2
        var variant: PreparedStyleModel? = try ModelPreparer(renderer: renderer).prepareVariant(of: model, execution: smaller)
        XCTAssertLessThan(try allowance(), originalAllowance)
        withExtendedLifetime(variant) {}
        variant = nil
        XCTAssertEqual(try allowance(), originalAllowance)
        let occupied = try model.reserveFrame(); defer { occupied.cancel() }
        XCTAssertThrowsError(try ModelPreparer(renderer: renderer).prepareVariant(of: model, execution: smaller))
    }
    func testVariantMinimumUsesItsOwnPrecisionAndGeometry() throws {
        let renderer = try LumeraRenderer()
        var bounded = execution; bounded.budget.maxResidentBytes = 4096
        let model = try ModelPreparer(renderer: renderer).prepare(StyleModelCompiler.compile(definition()), resources: .init(), execution: bounded)
        var larger = bounded; larger.width = 16; larger.height = 16
        XCTAssertThrowsError(try ModelPreparer(renderer: renderer).prepareVariant(of: model, execution: larger))
        var high = bounded; high.precision = .float32; high.width = 9; high.height = 9
        XCTAssertThrowsError(try ModelPreparer(renderer: LumeraRenderer(precision: .float32)).prepareVariant(of: model, execution: high))
    }

    func testRetainedFloat32OutputReducesOriginalModelAllowance() async throws {
        let renderer = try LumeraRenderer(), processor = try PhotoProcessor(renderer: renderer, working: working)
        let model = try ModelPreparer(renderer: renderer).prepare(StyleModelCompiler.compile(definition()), resources: .init(), execution: execution)
        let result = try await processor.process(.image(image()), descriptor: descriptor, recipe: recipe, calibration: nil, model: model, stamp: stamp)
        func allowance() throws -> Int {
            let reservation = try model.reserveFrame(); defer { reservation.cancel() }
            return reservation.execution.budget.maxResidentBytes
        }
        let before = try allowance()
        var high = execution; high.precision = .float32
        let exported = try await processor.render(result.snapshot, execution: high)
        XCTAssertLessThan(try allowance(), before)
        withExtendedLifetime(exported) {}
    }

    func testAbandonedOutputKeepsOnlyRetainedInputCharged() throws {
        let budget = try ModelFrameBudget(execution: execution, resourceBytes: 0)
        let lease = try budget.acquire(retainedInputBytes: 128)
        try lease.retainOutput(bytes: 256)
        lease.abortUnsubmitted()
        let next = try budget.acquire(retainedInputBytes: 0)
        XCTAssertEqual(next.allowance, execution.budget.maxResidentBytes - 128)
        withExtendedLifetime(lease) {}
    }

    func testCalibrationResidencyAggregatesAcrossPhotoVariantsBeforeUpload() async throws {
        let renderer = try LumeraRenderer()
        let asset = LUTAsset(name: "zero65", cubeText: "LUT_3D_SIZE 65\n" + String(repeating: "0 0 0\n", count: 65 * 65 * 65))
        var resource = ModelResourceDescriptor(id: "input-only", sha256: asset.sha256, dimension: 65)
        resource.role = .correctionLUT
        let resources = try ModelResourceSet(luts: [resource.id: asset])
        var bounded = execution; bounded.width = 64; bounded.height = 64
        let texture = MTLTextureDescriptor(); texture.textureType = .type3D; texture.pixelFormat = .rgba32Float
        texture.width = 65; texture.height = 65; texture.depth = 65; texture.storageMode = .shared; texture.usage = .shaderRead
        let cubeBytes = 65 * 65 * 65 * 16
        let resident = renderer.device.heapTextureSizeAndAlign(descriptor: texture).size + cubeBytes + asset.cubeText.utf8.count
        // Two uploads and one decode fit with image/entry headroom; a third
        // upload cannot fit on either tightly or generously aligned devices.
        bounded.budget.maxResidentBytes = 2 * resident + cubeBytes + 1024 * 1024
        let model = try ModelPreparer(renderer: renderer).prepare(StyleModelCompiler.compile(definition()), resources: .init(), execution: bounded)
        let normalized = try await InputAdapter(renderer: renderer, working: working).prepare(.image(image(width: 64, height: 64)), descriptor: descriptor, recipe: recipe, execution: bounded)
        var calibration = InputCalibration(id: "zero", source: descriptor, working: working)
        calibration.recipeDigest = try normalized.effectiveRecipe.digest(); calibration.resources = [resource]
        let processor = try PhotoProcessor(renderer: renderer, working: working, inputResources: resources)
        let photo = try await processor.process(.image(image(width: 64, height: 64)), descriptor: descriptor, recipe: recipe, calibration: calibration, model: model, stamp: stamp)
        let uploads = renderer.encoder.staticResourceStatistics.lutUploads
        _ = try await processor.process(.image(image(width: 64, height: 64)), descriptor: descriptor, recipe: recipe, calibration: calibration, model: model, stamp: stamp)
        XCTAssertEqual(renderer.encoder.staticResourceStatistics.lutUploads, uploads)
        var first = bounded; first.precision = .float32; first.width = 32; first.height = 32
        _ = try await processor.render(photo.snapshot, execution: first)
        var second = first; second.width = 16; second.height = 16
        let variant = try photo.snapshot.executionVariant(second)
        let before = variant.renderer.encoder.staticResourceStatistics.lutUploads
        do {
            _ = try await processor.render(photo.snapshot, execution: second)
            XCTFail("A third resident calibration escaped the shared model budget")
        } catch { }
        XCTAssertEqual(variant.renderer.encoder.staticResourceStatistics.lutUploads, before, "Reject before allocating/uploading the correction LUT")
    }

    func testPreparedReferenceNormalizerCannotAcquireAnUnchargedCalibration() async throws {
        let renderer = try LumeraRenderer()
        let model = try ModelPreparer(renderer: renderer).prepare(StyleModelCompiler.compile(definition()), resources: .init(), execution: execution)
        let normalizer = try model.prepareInputNormalizer(calibration: nil, resources: .init())
        let input = try await InputAdapter(renderer: renderer, working: working).prepare(.image(image()), descriptor: descriptor, recipe: recipe, execution: execution)
        var calibration = InputCalibration(id: "different", source: descriptor, working: working)
        calibration.recipeDigest = try input.effectiveRecipe.digest()
        do {
            _ = try await normalizer.normalize(input, calibration: calibration, resources: .init())
            XCTFail("Prepared normalizer accepted an unbound calibration")
        } catch { }
    }

    func testCalibrationCacheLeaseFollowsRetainedNormalizer() throws {
        let renderer = try LumeraRenderer()
        let model = try ModelPreparer(renderer: renderer).prepare(StyleModelCompiler.compile(definition()), resources: .init(), execution: execution)
        let asset = LUTAsset(name: "zero", cubeText: "LUT_3D_SIZE 2\n" + String(repeating: "0 0 0\n", count: 8))
        var descriptor = ModelResourceDescriptor(id: "correction", sha256: asset.sha256, dimension: 2); descriptor.role = .correctionLUT
        let resources = try ModelResourceSet(luts: [descriptor.id: asset])
        var calibration = InputCalibration(id: "bound", source: self.descriptor, working: working); calibration.resources = [descriptor]
        func allowance() throws -> Int {
            let reservation = try model.reserveFrame(); defer { reservation.cancel() }
            return reservation.execution.budget.maxResidentBytes
        }
        let initial = try allowance()
        var variant: PreparedStyleModel? = try ModelPreparer(renderer: renderer).prepareVariant(of: model, execution: execution)
        var normalizer: InputNormalizer? = try variant!.prepareInputNormalizer(calibration: calibration, resources: resources)
        let charged = try allowance()
        XCTAssertLessThan(charged, initial)
        XCTAssertTrue(normalizer === (try variant!.prepareInputNormalizer(calibration: calibration, resources: resources)))
        XCTAssertEqual(try allowance(), charged, "Cache hits must not reserve the LUT again")
        variant = nil
        XCTAssertEqual(try allowance(), charged, "A retained normalizer still owns its correction resources")
        withExtendedLifetime(normalizer) {}
        normalizer = nil
        XCTAssertEqual(try allowance(), initial)
    }

    func testCalibrationLUTPreflightRejectsTextAndRawDimensionMismatchWithoutDecoding() throws {
        let largeHeader = LUTAsset(name: "wrong dimension", cubeText: "LUT_3D_SIZE 65\nnot numeric samples")
        XCTAssertThrowsError(try largeHeader.preflightDimension(2))
        let raw = LUTAsset(name: "raw", cube: CubeLUT(size: 3, rgba: Array(repeating: 0, count: 3 * 3 * 3 * 4)))
        XCTAssertThrowsError(try raw.preflightDimension(2))
        let samplesOnly = LUTAsset(name: "defer values", cubeText: "LUT_3D_SIZE 2\n" + String(repeating: "not numeric samples\n", count: 8))
        XCTAssertNoThrow(try samplesOnly.preflightDimension(2), "The bounded preflight must not decode values")
        XCTAssertThrowsError(try samplesOnly.decodedCube())
        let extra = LUTAsset(name: "extra row", cubeText: "LUT_3D_SIZE 2\n" + String(repeating: "0 0 0\n", count: 9))
        XCTAssertThrowsError(try extra.preflightDimension(2))
    }

}

extension PhotoProcessorTests {
    func testExplicitExportBypassesGlowAndHalationForFullTiledAndRegionOutput() async throws {
        let renderer = try LumeraRenderer(), processor = try PhotoProcessor(renderer: renderer, working: working)
        var definition = definition()
        definition.appearance.parameters.glow.enabled = true
        definition.appearance.parameters.glow.amount = 0.7
        definition.appearance.parameters.glow.threshold = 0.3
        definition.appearance.parameters.halation.enabled = true
        definition.appearance.parameters.halation.amount = 0.6
        definition.appearance.parameters.halation.threshold = 0.3
        var preview = execution; preview.width = 256; preview.height = 256
        let model = try ModelPreparer(renderer: renderer).prepare(StyleModelCompiler.compile(definition), resources: .init(), execution: preview)
        let bright = image(0.85, width: 128, height: 256).transformed(by: .init(translationX: 128, y: 0))
        let source = bright.composited(over: image(0.1, width: 256, height: 256))
        let result = try await processor.process(.image(source), descriptor: descriptor, recipe: recipe, calibration: nil, model: model, stamp: stamp)
        var export = preview
        export.previewGlow = false
        export.glowScale = .quarter; export.halationScale = .eighth; export.softeningScale = .half
        let full = try await processor.render(result.snapshot, execution: export)
        let tiled = try await processor.render(result.snapshot, execution: export, tiled: true)
        let region = CGRect(x: 126, y: 120, width: 4, height: 8)
        let cropped = try await processor.render(result.snapshot, region: region, execution: export)
        let expected = pixels(source)
        XCTAssertGreaterThan(try XCTUnwrap(zip(pixels(result.frame.image), expected).map { abs($0 - $1) }.max()), 0.03)
        XCTAssertEqual(full.execution, export)
        let expectedRegion = pixels(source.cropped(to: region))
        for (frame, reference) in [(full, expected), (tiled, expected), (cropped, expectedRegion)] {
            let actual = pixels(frame.image)
            XCTAssertEqual(actual.count, reference.count)
            XCTAssertLessThan(try XCTUnwrap(zip(actual, reference).map { abs($0 - $1) }.max()), 0.003)
        }
    }

    func testDevelopedProRAWPreservesCaptureOriginWithoutRAWReplay() async throws {
        let renderer = try LumeraRenderer(), processor = try PhotoProcessor(renderer: renderer, working: working)
        let model = try ModelPreparer(renderer: renderer).prepare(StyleModelCompiler.compile(definition()), resources: .init(), execution: execution)
        var d = descriptor; d.path = .proRAW
        let result = try await processor.process(.image(image()), descriptor: d, recipe: recipe, calibration: nil, model: model, stamp: stamp)
        XCTAssertEqual(result.snapshot.input.source.descriptor.path, .proRAW)
        XCTAssertEqual(result.snapshot.input.source.inputDevelopment, .decodedPixels)
        XCTAssertFalse(result.snapshot.canRedevelopRAW)
        XCTAssertNil(result.snapshot.input.source.effectiveRecipe.decoderVersion)
        var full = execution; full.precision = .float32
        let exported = try await processor.render(result.snapshot, execution: full)
        XCTAssertEqual(exported.texture?.pixelFormat, .rgba32Float)
    }

    func testExternalRAWURLDataAndPhotoReplayUseActualFilterAndFrozenPayload() async throws {
        guard let path = ProcessInfo.processInfo.environment["LUMERA_RAW_TEST_FILE"] else {
            throw XCTSkip("Set LUMERA_RAW_TEST_FILE to a supported RAW fixture")
        }
        let url = URL(fileURLWithPath: path), bytes = try Data(contentsOf: url)
        let original = try XCTUnwrap(CIRAWFilter(imageURL: url))
        let decoder = try XCTUnwrap(original.supportedDecoderVersions.first)
        let defaultExposure = original.baselineExposure
        let recipe = InputRecipe(id: "ci", backend: "coreImage", version: "1")
        var d = descriptor; d.path = .raw
        var e = execution
        let expected = try XCTUnwrap(original.outputImage).extent
        e.width = Int(expected.width); e.height = Int(expected.height)
        e.budget.maxResidentBytes = 512 * 1024 * 1024
        let renderer = try LumeraRenderer(), processor = try PhotoProcessor(renderer: renderer, working: working)
        let adapter = try InputAdapter(renderer: renderer, working: working)
        let model = try ModelPreparer(renderer: renderer).prepare(StyleModelCompiler.compile(definition()), resources: .init(), execution: e)
        var payload = Data([2])
        let config = try RAWDevelopmentConfiguration(identifier: "host", version: "1", payload: payload) { raw, frozen in
            XCTAssertEqual(frozen, Data([2]))
            XCTAssertFalse(raw.isDraftModeEnabled)
            XCTAssertEqual(raw.extendedDynamicRangeAmount, 0)
            raw.decoderVersion = decoder
            raw.baselineExposure = defaultExposure - Float(frozen[0])
        }
        payload[0] = 5
        let result = try await processor.process(.rawURL(url), descriptor: d, recipe: recipe, calibration: nil,
            model: model, stamp: stamp, rawConfiguration: config)
        let dataInput = try await adapter.prepare(.rawData(bytes), descriptor: d, recipe: recipe, execution: e, rawConfiguration: config)
        XCTAssertEqual(dataInput.sourceID, result.snapshot.input.sourceID)
        XCTAssertEqual(dataInput.effectiveRecipe.decoderVersion, decoder.rawValue)
        XCTAssertEqual(dataInput.effectiveRecipe.externalRAWConfiguration, config.identity)
        XCTAssertEqual(dataInput.inputDevelopment, .rawDevelopment)
        XCTAssertTrue(result.snapshot.canRedevelopRAW)
        let unedited = try await adapter.prepare(.rawData(bytes), descriptor: d, recipe: recipe, execution: e)
        XCTAssertNotEqual(pixels(dataInput.image), pixels(unedited.image))
        var high = e; high.precision = .float32
        let replay = try await processor.render(result.snapshot, execution: high)
        XCTAssertEqual(replay.texture?.pixelFormat, .rgba32Float)
        XCTAssertEqual(pixels(replay.image)[0], pixels(result.frame.image)[0], accuracy: 0.003)
    }

    func testExternalRAWCallbackErrorIsPropagated() async throws {
        enum CallbackError: Error { case rejected }
        guard let path = ProcessInfo.processInfo.environment["LUMERA_RAW_TEST_FILE"] else {
            throw XCTSkip("Set LUMERA_RAW_TEST_FILE to a supported RAW fixture")
        }
        let url = URL(fileURLWithPath: path)
        let adapter = try InputAdapter(renderer: LumeraRenderer(), working: working)
        var d = descriptor; d.path = .raw
        let recipe = InputRecipe(id: "ci", backend: "coreImage", version: "1")
        let config = try RAWDevelopmentConfiguration(identifier: "host", version: "1", payload: Data()) { _, _ in throw CallbackError.rejected }
        do {
            _ = try await adapter.prepare(.rawURL(url), descriptor: d, recipe: recipe, execution: execution, rawConfiguration: config)
            XCTFail("Callback rejection was ignored")
        } catch CallbackError.rejected { } catch { XCTFail("Callback error was replaced by \(error)") }
    }
}

extension PhotoProcessorTests {
    func testConflictingRAWControlsFailBeforeOpeningSource() async throws {
        let renderer = try LumeraRenderer()
        let processor = try PhotoProcessor(renderer: renderer, working: working)
        let model = try ModelPreparer(renderer: renderer).prepare(StyleModelCompiler.compile(definition()), resources: .init(), execution: execution)
        let config = try RAWDevelopmentConfiguration(identifier: "host", version: "1", payload: Data()) { _, _ in }
        var recipe = self.recipe
        recipe.rawSettings = [.init(key: .exposureEV, value: 1)]
        var descriptor = self.descriptor
        descriptor.path = .raw
        let source = SourceImage.rawURL(FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        do {
            _ = try await processor.process(source, descriptor: descriptor, recipe: recipe, calibration: nil, model: model,
                                            stamp: stamp, rawConfiguration: config)
            XCTFail("Mixed RAW controls were accepted")
        } catch {
            XCTAssertEqual(error.localizedDescription, "External RAW configuration and legacy RAW controls cannot be combined")
        }
        XCTAssertThrowsError(try processor.makeSource(source, descriptor: descriptor, recipe: recipe, calibration: nil, rawConfiguration: config)) {
            XCTAssertEqual($0.localizedDescription, "External RAW configuration and legacy RAW controls cannot be combined")
        }
    }

    func testReusablePhotoRebuildsWithoutPinningInputThroughOutput() async throws {
        let renderer = try LumeraRenderer()
        let processor = try PhotoProcessor(renderer: renderer, working: working)
        let model = try ModelPreparer(renderer: renderer).prepare(StyleModelCompiler.compile(definition()), resources: .init(), execution: execution)
        let source = try processor.makeSource(.image(image(0.30001)), descriptor: descriptor, recipe: recipe, calibration: nil)
        let cache = try PhotoInputCache(maxResidentBytes: 1 << 20)
        let first = try await processor.process(source, cache: cache, model: model, stamp: stamp)
        let before = await cache.residentBytes
        XCTAssertGreaterThan(before, 0)
        await cache.evictAll()
        let after = await cache.residentBytes
        XCTAssertEqual(after, 0, "The snapshot and completed result must not own cached pixels")
        let remaining = try model.reserveFrame()
        XCTAssertEqual(remaining.execution.budget.maxResidentBytes, execution.budget.maxResidentBytes - first.frame.texture!.allocatedSize)
        remaining.cancel()
        let rebuilt = try await processor.render(first.snapshot, cache: cache, execution: execution, retention: .evictAfterUse)
        XCTAssertNotEqual(rebuilt.inputID, first.frame.inputID)
        XCTAssertEqual(pixels(rebuilt.image), pixels(first.frame.image))
        let discarded = await cache.residentBytes
        XCTAssertEqual(discarded, 0)
        var high = execution
        high.precision = .float32
        let exported = try await processor.render(first.snapshot, cache: cache, execution: high, retention: .evictAfterUse)
        XCTAssertEqual(exported.texture?.pixelFormat, .rgba32Float)
        XCTAssertEqual(pixels(exported.image)[0], 0.30001, accuracy: 0.00001)
    }

    func testReusablePhotoSwapsModelsAndObservesNewRequirements() async throws {
        let renderer = try LumeraRenderer(), processor = try PhotoProcessor(renderer: renderer, working: working)
        let preparer = ModelPreparer(renderer: renderer)
        var firstDefinition = definition()
        firstDefinition.observations.features = [.init(id: "red", statistic: .meanRed)]
        let firstModel = try preparer.prepare(StyleModelCompiler.compile(firstDefinition), resources: .init(), execution: execution)
        var secondDefinition = firstDefinition
        secondDefinition.appearance.parameters.color.exposureEV = 1
        let secondModel = try preparer.prepare(StyleModelCompiler.compile(secondDefinition), resources: .init(), execution: execution)
        var thirdDefinition = secondDefinition
        thirdDefinition.observations.features = [.init(id: "green", statistic: .meanGreen)]
        let thirdModel = try preparer.prepare(StyleModelCompiler.compile(thirdDefinition), resources: .init(), execution: execution)
        let source = try processor.makeSource(.image(image()), descriptor: descriptor, recipe: recipe, calibration: nil)
        let cache = try PhotoInputCache(maxResidentBytes: 1 << 20)
        let first = try await processor.process(source, cache: cache, model: firstModel, stamp: stamp)
        let second = try await processor.process(source, cache: cache, model: secondModel, stamp: stamp, reusing: first.snapshot)
        XCTAssertEqual(first.frame.inputID, second.frame.inputID)
        XCTAssertEqual(first.snapshot.observations, second.snapshot.observations)
        XCTAssertEqual(second.snapshot.automatic.parameters.color.exposureEV, 1)
        let third = try await processor.process(source, cache: cache, model: thirdModel, stamp: stamp, reusing: second.snapshot)
        XCTAssertEqual(third.frame.inputID, first.frame.inputID)
        XCTAssertEqual(third.snapshot.observations.features.map(\.id), ["green"])
        let revised = try processor.makeSource(.image(image(0.2)), descriptor: descriptor, recipe: recipe, calibration: nil)
        let updated = try await processor.process(revised, cache: cache, model: firstModel, stamp: stamp, reusing: first.snapshot)
        XCTAssertNotEqual(updated.frame.inputID, first.frame.inputID)
        XCTAssertNotEqual(updated.snapshot.observations.features, first.snapshot.observations.features)
    }
}

extension PhotoProcessorTests {
    func testCacheEvictionPinsInputThroughActiveGPUWork() async throws {
        let renderer = try LumeraRenderer(), processor = try PhotoProcessor(renderer: renderer, working: working)
        let model = try ModelPreparer(renderer: renderer).prepare(StyleModelCompiler.compile(definition()), resources: .init(), execution: execution)
        let source = try processor.makeSource(.image(image()), descriptor: descriptor, recipe: recipe, calibration: nil)
        let cache = try PhotoInputCache(maxResidentBytes: 1 << 20)
        let first = try await processor.process(source, cache: cache, model: model, stamp: stamp)
        let resident = await cache.residentBytes
        let event = try XCTUnwrap(renderer.device.makeSharedEvent())
        let blocker = try XCTUnwrap(renderer.queue.makeCommandBuffer())
        blocker.encodeWaitForEvent(event, value: 1)
        blocker.commit()
        defer { event.signaledValue = 1 }
        let render = Task { try await processor.render(first.snapshot, cache: cache, execution: execution) }
        var active = false
        for _ in 0..<1000 {
            guard let probe = try? model.reserveFrame() else { active = true; break }
            probe.cancel()
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(active)
        await cache.evictAll()
        let pinned = await cache.residentBytes
        XCTAssertEqual(pinned, resident)
        event.signaledValue = 1
        let output = try await render.value
        XCTAssertEqual(output.inputID, first.frame.inputID)
        let released = await cache.residentBytes
        XCTAssertEqual(released, 0)
    }

    func testSharedPhotoBuildSurvivesWaiterCancellationWithoutPublishingAfterEviction() async throws {
        enum UnexpectedBuild: Error { case duplicate }
        let renderer = try LumeraRenderer(), processor = try PhotoProcessor(renderer: renderer, working: working)
        let model = try ModelPreparer(renderer: renderer).prepare(StyleModelCompiler.compile(definition()), resources: .init(), execution: execution)
        let source = try processor.makeSource(.image(image()), descriptor: descriptor, recipe: recipe, calibration: nil)
        let cache = try PhotoInputCache(maxResidentBytes: 1 << 20)
        let key = PhotoInputKey(source: source, model: model)
        let (started, start) = AsyncStream<Void>.makeStream()
        let (unblock, finish) = AsyncStream<Void>.makeStream()
        let (joined, join) = AsyncStream<Void>.makeStream()
        let first = Task {
            try await cache.acquire(key, retention: .retain) {
                start.yield()
                var signal = unblock.makeAsyncIterator()
                _ = await signal.next()
                let reservation = try model.reserveFrame()
                defer { reservation.cancel() }
                let normalized = try await InputAdapter(renderer: renderer, working: source.working).prepare(
                    source.lease.source, descriptor: source.descriptor, recipe: source.recipe, execution: reservation.execution)
                let input = try await InputNormalizer(renderer: renderer).normalize(normalized, calibration: nil, resources: .init())
                return try reservation.finishPreparingPhotoInput(input)
            }
        }
        var startSignal = started.makeAsyncIterator()
        _ = await startSignal.next()
        let second = Task {
            try await cache.acquireForTest(key, entered: { join.yield() }) { throw UnexpectedBuild.duplicate }
        }
        var joinSignal = joined.makeAsyncIterator()
        _ = await joinSignal.next()
        await cache.evictAll()
        first.cancel()
        finish.yield()
        do { _ = try await first.value; XCTFail("Cancelled waiter received the shared input") }
        catch { XCTAssertTrue(error is CancellationError) }
        let entry = try await second.value
        let pinned = await cache.residentBytes
        XCTAssertEqual(pinned, entry.origin.input.residentStorageBytes)
        do {
            _ = try await cache.acquire(key, retention: .retain) { throw UnexpectedBuild.duplicate }
            XCTFail("An evicted in-flight build repopulated the cache")
        } catch { XCTAssertTrue(error is UnexpectedBuild) }
    }

    func testReusableRAWSourceRebuildsWithConfigurationAndRejectsURLMutationOnCacheHit() async throws {
        guard let path = ProcessInfo.processInfo.environment["LUMERA_RAW_TEST_FILE"] else {
            throw XCTSkip("Set LUMERA_RAW_TEST_FILE to a supported RAW fixture")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).dng")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let extent = try XCTUnwrap(CIRAWFilter(imageURL: url)?.outputImage).extent
        var execution = self.execution
        execution.width = Int(extent.width)
        execution.height = Int(extent.height)
        execution.budget.maxResidentBytes = 512 * 1024 * 1024
        let renderer = try LumeraRenderer(), processor = try PhotoProcessor(renderer: renderer, working: working)
        let model = try ModelPreparer(renderer: renderer).prepare(StyleModelCompiler.compile(definition()), resources: .init(), execution: execution)
        var descriptor = self.descriptor
        descriptor.path = .raw
        let config = try RAWDevelopmentConfiguration(identifier: "host", version: "1", payload: Data([2])) { raw, payload in
            raw.baselineExposure -= Float(payload[0])
        }
        let source = try processor.makeSource(.rawURL(url), descriptor: descriptor, recipe: recipe, calibration: nil, rawConfiguration: config)
        let cache = try PhotoInputCache(maxResidentBytes: 256 * 1024 * 1024)
        let result = try await processor.process(source, cache: cache, model: model, stamp: stamp)
        XCTAssertTrue(result.snapshot.canRedevelopRAW)
        XCTAssertEqual(result.snapshot.inputFacts.effectiveRecipe?.externalRAWConfiguration, config.identity)
        await cache.evictAll()
        var high = execution
        high.precision = .float32
        let rebuilt = try await processor.render(result.snapshot, cache: cache, execution: high)
        XCTAssertNotEqual(result.frame.inputID, rebuilt.inputID)
        XCTAssertEqual(rebuilt.texture?.pixelFormat, .rgba32Float)
        XCTAssertEqual(pixels(result.frame.image)[0], pixels(rebuilt.image)[0], accuracy: 0.003)
        try Data("changed".utf8).write(to: url)
        do {
            _ = try await processor.render(result.snapshot, cache: cache, execution: high)
            XCTFail("An existing RAW cache entry accepted a modified source file")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Photo source bytes changed; create a new decision")
        }
    }
}

extension PhotoInputCache {
    fileprivate func acquireForTest(_ key: PhotoInputKey, entered: @Sendable () -> Void,
                                    build: @escaping @Sendable () async throws -> PhotoInputResidency) async throws -> PhotoInputLease {
        entered()
        return try await acquire(key, retention: .retain, build: build)
    }
}

extension PhotoProcessorTests {
    func testBoundedSnapshotRegionExportMatchesFullRender() async throws {
        let renderer = try LumeraRenderer(), processor = try PhotoProcessor(renderer: renderer, working: working)
        var definition = definition()
        definition.observations.features = [.init(id: "mean", statistic: .meanRed)]
        definition.appearance.parameters.vignette.enabled = true
        definition.appearance.parameters.vignette.amountEV = 1
        definition.appearance.parameters.vignette.centerX = 0.2
        let execution = ExecutionProfile(width: 701, height: 509, budget: .init(maxInFlightFrames: 1, maxResidentBytes: 64 * 1024 * 1024))
        let model = try ModelPreparer(renderer: renderer).prepareStreaming(StyleModelCompiler.compile(definition), resources: .init(), execution: execution)
        let source = try processor.makeSource(.image(image(width: 701, height: 509)), descriptor: descriptor, recipe: recipe, calibration: nil)
        let snapshot = try await processor.processStreaming(source, model: model, stamp: stamp) { _ in }
        let region = CGRect(x: 97, y: 81, width: 311, height: 273)
        var data = Data(count: 311 * 273 * 8)
        let result = try await processor.renderStreaming(snapshot, execution: execution, region: region) { tile in
            data.withUnsafeMutableBytes { dest in
                for row in 0..<Int(tile.core.height) {
                    let y = 272 - (Int(tile.core.minY - region.minY) + row)
                    dest.baseAddress!.advanced(by: (y * 311 + Int(tile.core.minX - region.minX)) * 8)
                        .copyMemory(from: tile.bytes.baseAddress!.advanced(by: row * tile.bytesPerRow), byteCount: Int(tile.core.width) * 8)
                }
            }
        }
        XCTAssertEqual(result.observations, snapshot.observations)
        XCTAssertEqual(result.controls.automatic, snapshot.automatic)
        let actual = CIImage(bitmapData: data, bytesPerRow: 311 * 8, size: region.size, format: .RGBAh, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        let expected = try await processor.process(.image(image(width: 701, height: 509)), descriptor: descriptor, recipe: recipe, calibration: nil, model: model, stamp: stamp)
        let crop = expected.frame.image.cropped(to: region).transformed(by: .init(translationX: -region.minX, y: -region.minY))
        for (a,b) in zip(pixels(actual), pixels(crop)) { XCTAssertEqual(a,b,accuracy:0.003) }
    }
}

extension PhotoProcessorTests {
    func testStreamingCalibratedLUTLedgerCeilingAndNoRetainedArena() async throws {
        let renderer = try LumeraRenderer()
        let asset = LUTAsset(name: "identity", cubeText: "LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1")
        let resources = try ModelResourceSet(luts: ["lut": asset])
        var definition = definition()
        definition.appearance.resources = [.init(id: "lut", sha256: asset.sha256, dimension: 2)]
        definition.appearance.lutWeights = [.init(resourceID: "lut", weight: 1)]
        let model = try ModelPreparer(renderer: renderer).prepareStreaming(StyleModelCompiler.compile(definition), resources: resources, execution: execution)
        let normalized = try await InputAdapter(renderer: renderer, working: working).prepare(.image(image()), descriptor: descriptor, recipe: recipe, execution: execution)
        var calibration = InputCalibration(id: "half", source: descriptor, working: working)
        calibration.recipeDigest = try normalized.effectiveRecipe.digest()
        calibration.correction.matrix.values = [0.5,0,0,0,0.5,0,0,0,0.5]
        var correction = ModelResourceDescriptor(id: "lut", sha256: asset.sha256, dimension: 2); correction.role = .correctionLUT
        calibration.resources = [correction]
        let processor = try PhotoProcessor(renderer: renderer, working: working, inputResources: resources)
        let source = try processor.makeSource(.image(image()), descriptor: descriptor, recipe: recipe, calibration: calibration)
        let snapshot = try await processor.processStreaming(source, model: model, stamp: stamp) { _ in }
        XCTAssertEqual(renderer.encoder.cachedTextureBytes, 0)
        var smaller = execution; smaller.width = 2; smaller.height = 2
        let result = try await processor.renderStreaming(snapshot, execution: smaller) { _ in }
        XCTAssertEqual(result.peakKnownOwnedBytes, execution.budget.maxResidentBytes)
        XCTAssertEqual(renderer.encoder.cachedTextureBytes, 0)
        let admission = try model.reserveFrame(); defer { admission.cancel() }
        XCTAssertLessThan(admission.execution.budget.maxResidentBytes, result.peakKnownOwnedBytes, "Metric includes base, correction and variant resources omitted by the frame slice")
    }
    func testFreshStreamingSameDescriptorDifferentRevisionsReobserves() async throws {
        let renderer = try LumeraRenderer(), processor = try PhotoProcessor(renderer: renderer, working: working)
        var definition = definition(); definition.observations.features = [.init(id: "mean", statistic: .meanRed)]
        let model = try ModelPreparer(renderer: renderer).prepareStreaming(StyleModelCompiler.compile(definition), resources: .init(), execution: execution)
        let first = try processor.makeSource(.image(image(0.1)), descriptor: descriptor, recipe: recipe, calibration: nil)
        let second = try processor.makeSource(.image(image(0.8)), descriptor: descriptor, recipe: recipe, calibration: nil)
        let a = try await processor.processStreaming(first, model: model, stamp: stamp) { _ in }
        let b = try await processor.processStreaming(second, model: model, stamp: stamp) { _ in }
        XCTAssertNotEqual(first.revision, second.revision)
        XCTAssertEqual(a.inputFacts.sourceID, b.inputFacts.sourceID)
        XCTAssertNotEqual(a.observations.features, b.observations.features)
        let replay = try await processor.renderStreaming(a, execution: execution) { _ in }
        XCTAssertEqual(replay.observations, a.observations)
    }
}
