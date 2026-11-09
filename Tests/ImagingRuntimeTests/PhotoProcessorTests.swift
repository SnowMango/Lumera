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
    func definition() -> CameraModel {
        var m = CameraModel(identity: .init(id: "synthetic", camera: "fixture", mode: "manual"))
        m.compatibility.referenceRenditionIDs = [working.referenceRenditionID]
        m.edits.overrideTargets = ["color.exposureEV"]
        return m
    }
    func testDefaultPhotoUsesOneCalibrationAndOriginalObservation() async throws {
        let renderer = try LumeraRenderer(), processor = try PhotoProcessor(renderer: renderer, working: working)
        var m = definition(); m.observations.features = [.init(id: "mean", statistic: .meanRed)]
        let model = try ModelPreparer(renderer: renderer).prepare(CameraModelCompiler.compile(m), resources: .init(), execution: execution)
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
        let model = try ModelPreparer(renderer: renderer).prepare(CameraModelCompiler.compile(m), resources: .init(), execution: execution)
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
        let model = try ModelPreparer(renderer: renderer).prepare(CameraModelCompiler.compile(definition()), resources: .init(), execution: execution)
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
        let model = try ModelPreparer(renderer: renderer).prepare(CameraModelCompiler.compile(definition()), resources: .init(), execution: execution)
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
        let compiled = try CameraModelCompiler.compile(m)
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
        let model = try ModelPreparer(renderer: renderer).prepare(CameraModelCompiler.compile(definition()), resources: .init(), execution: execution)
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
        let model = try ModelPreparer(renderer: renderer).prepare(CameraModelCompiler.compile(definition()), resources: .init(), execution: execution)
        let result = try await processor.process(.image(image()), descriptor: descriptor, recipe: recipe, calibration: nil, model: model, stamp: stamp)
        var changed = execution; changed.budget.maxResidentBytes *= 2
        do {
            _ = try await processor.render(result.snapshot, execution: changed)
            XCTFail("Snapshot replaced its shared memory budget")
        } catch { }
    }

    func testSnapshotCachesCompleteExecutionVariants() async throws {
        let renderer = try LumeraRenderer(), processor = try PhotoProcessor(renderer: renderer, working: working)
        let model = try ModelPreparer(renderer: renderer).prepare(CameraModelCompiler.compile(definition()), resources: .init(), execution: execution)
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
        let model = try ModelPreparer(renderer: renderer).prepare(CameraModelCompiler.compile(definition), resources: .init(luts: ["lut": asset]), execution: execution)
        func allowance() throws -> Int {
            let reservation = try model.reserveFrame(); defer { reservation.cancel() }
            return reservation.execution.budget.maxResidentBytes
        }
        let originalAllowance = try allowance()
        var smaller = execution; smaller.width = 2; smaller.height = 2
        var variant: PreparedCameraModel? = try ModelPreparer(renderer: renderer).prepareVariant(of: model, execution: smaller)
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
        let model = try ModelPreparer(renderer: renderer).prepare(CameraModelCompiler.compile(definition()), resources: .init(), execution: bounded)
        var larger = bounded; larger.width = 16; larger.height = 16
        XCTAssertThrowsError(try ModelPreparer(renderer: renderer).prepareVariant(of: model, execution: larger))
        var high = bounded; high.precision = .float32; high.width = 9; high.height = 9
        XCTAssertThrowsError(try ModelPreparer(renderer: LumeraRenderer(precision: .float32)).prepareVariant(of: model, execution: high))
    }

    func testRetainedFloat32OutputReducesOriginalModelAllowance() async throws {
        let renderer = try LumeraRenderer(), processor = try PhotoProcessor(renderer: renderer, working: working)
        let model = try ModelPreparer(renderer: renderer).prepare(CameraModelCompiler.compile(definition()), resources: .init(), execution: execution)
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
        let model = try ModelPreparer(renderer: renderer).prepare(CameraModelCompiler.compile(definition()), resources: .init(), execution: bounded)
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
        let model = try ModelPreparer(renderer: renderer).prepare(CameraModelCompiler.compile(definition()), resources: .init(), execution: execution)
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
        let model = try ModelPreparer(renderer: renderer).prepare(CameraModelCompiler.compile(definition()), resources: .init(), execution: execution)
        let asset = LUTAsset(name: "zero", cubeText: "LUT_3D_SIZE 2\n" + String(repeating: "0 0 0\n", count: 8))
        var descriptor = ModelResourceDescriptor(id: "correction", sha256: asset.sha256, dimension: 2); descriptor.role = .correctionLUT
        let resources = try ModelResourceSet(luts: [descriptor.id: asset])
        var calibration = InputCalibration(id: "bound", source: self.descriptor, working: working); calibration.resources = [descriptor]
        func allowance() throws -> Int {
            let reservation = try model.reserveFrame(); defer { reservation.cancel() }
            return reservation.execution.budget.maxResidentBytes
        }
        let initial = try allowance()
        var variant: PreparedCameraModel? = try ModelPreparer(renderer: renderer).prepareVariant(of: model, execution: execution)
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
