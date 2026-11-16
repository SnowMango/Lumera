import XCTest
import CoreImage
import Metal
import ImagingCore
@testable import ImageRendering

final class NoWorkSubmissionTests: XCTestCase {
    struct Fixture {
        let renderer: LumeraRenderer
        let model: PreparedStyleModel
        let input: PreparedInput
        var controls: ResolvedControls {
            let automatic = AutomaticControls(parameters: model.compiled.definition.appearance.parameters,
                modelID: model.compiled.identity, sourceID: input.sourceID, calibrationID: input.calibrationID,
                featureDigest: model.compiled.featureDigest)
            return .init(automatic: automatic, parameters: automatic.parameters, lutWeights: [])
        }
        func plan(_ controls: ResolvedControls? = nil) throws -> FrameRenderPlan {
            try RenderPlanner().plan(controls ?? self.controls, input: input, model: model,
                stamp: .init(streamID: "no-work", generation: 0, index: 1, presentationTime: 1, duration: 1 / 30))
        }
    }
    func fixture(id: String = "neutral", precision: ExecutionPrecision = .float16,
                 range: ModelDynamicRange = .sdr, width: Int = 4) async throws -> Fixture {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let renderer = try LumeraRenderer(precision: precision == .float16 ? .float16 : .float32)
        var execution = ExecutionProfile(width: width, height: width,
            budget: .init(maxInFlightFrames: 1, maxResidentBytes: 32 * 1024 * 1024))
        execution.precision = precision; execution.dynamicRange = range
        var definition = StyleModel(identity: .init(id: id, name: id))
        definition.compatibility.dynamicRanges = [range]
        let model = try ModelPreparer(renderer: renderer).prepare(StyleModelCompiler.compile(definition), resources: .init(), execution: execution)
        var working = WorkingImageContract(referenceRenditionID: "fixture")
        working.dynamicRange = range
        if range == .edr { working.valueBounds = .finite(.init(lower: -0.25, upper: 2)) }
        let preparer = try model.prepareRealtimeInput(working: working)
        var descriptor = SourceDescriptor(id: "input", path: .processedPhoto); descriptor.recipeID = "ci"
        let pixel: [Float] = [range == .edr ? -0.1 : 0.25, 0.5, range == .edr ? 1.5 : 0.75, 1]
        let rgba = Array(repeating: pixel, count: 16).flatMap { $0 }
        let image = CIImage(bitmapData: rgba.withUnsafeBytes { Data($0) }, bytesPerRow: 4 * 16,
            size: CGSize(width: 4, height: 4), format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedSRGB))
        let input = try await preparer.prepare(.image(image), descriptor: descriptor,
            recipe: .init(id: "ci", backend: "coreImage", version: "1", decodedRendition: .baseImage),
            execution: execution, rawOverrides: [], rawConfiguration: nil, trustedNormalizedRGBBounds: nil)
        return .init(renderer: renderer, model: model, input: input)
    }
    func pixels(_ image: CIImage) -> [Float] {
        var values = [Float](repeating: 0, count: 4)
        values.withUnsafeMutableBytes {
            CIContext().render(image, toBitmap: $0.baseAddress!, rowBytes: 16,
                bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf,
                colorSpace: CGColorSpace(name: CGColorSpace.extendedSRGB))
        }
        return values
    }

    func testNeutralWorkDoesNotDependOnModelName() async throws {
        for id in ["lumera-basic-v1", "another-neutral-model"] {
            let f = try await fixture(id: id), plan = try f.plan()
            XCTAssertFalse(try f.renderer.encoder.workRequirements(for: plan).requiresPixelProcessing)
            plan.cancel()
        }
    }
    func testDynamicControlsInvalidateNeutralWork() async throws {
        let f = try await fixture()
        for exposure in [0.0, -1, 0, 1, 0] {
            var controls = f.controls; controls.parameters.color.exposureEV = exposure
            let plan = try f.plan(controls)
            XCTAssertEqual(try f.renderer.encoder.workRequirements(for: plan).requiresPixelProcessing, exposure != 0)
            plan.cancel()
        }
    }
    func testLUTInputEditsGeometryAndFormatRequireWork() async throws {
        let f = try await fixture()
        var controls = f.controls; controls.inputExposureEV = -1
        let edited = try f.plan(controls)
        XCTAssertTrue(try f.renderer.encoder.workRequirements(for: edited).requiresPixelProcessing); edited.cancel()
        let resized = try await fixture(width: 2), smaller = try resized.plan()
        XCTAssertTrue(try resized.renderer.encoder.workRequirements(for: smaller).requiresPixelProcessing); smaller.cancel()
        XCTAssertTrue(FrameWorkRequirements(hasEffects: false, needsResize: false,
                                            inputFormat: .rgba32Float, outputFormat: .rgba16Float).requiresPixelProcessing)
        let lut = IndependentLUTTests.asset(0.5)
        let style = try f.renderer.encoder.prepare(ResolvedStyle(parameters: f.controls.parameters), lut: lut)
        let original = try f.plan()
        let lutPlan = FrameRenderPlan(controls: original.controls, input: f.input, model: f.model,
            style: style, prefix: nil, request: original.request, stamp: original.stamp,
            lease: original.lease, workingSet: original.workingSet)
        XCTAssertTrue(try f.renderer.encoder.workRequirements(for: lutPlan).requiresPixelProcessing)
        original.cancel(); lutPlan.cancel()
    }
    func testNoWorkCreatesNoModelCommandOrCopy() async throws {
        for precision in [ExecutionPrecision.float16, .float32] {
            let f = try await fixture(precision: precision)
            let plan = try f.plan()
            var accepted = 0
            let submission = try f.renderer.submit(f.input, plan: plan, beforeCommit: { accepted += 1 })
            XCTAssertFalse(submission.usesGPU)
            async let a = submission.value()
            async let b = submission.value()
            let (first, second) = try await (a, b)
            XCTAssertTrue(first.frame === second.frame)
            XCTAssertTrue(first.frame.texture === f.input.texture, "No output allocation/copy")
            XCTAssertEqual(accepted, 1)
            XCTAssertEqual(first.frame.resolvedControls, f.controls)
            XCTAssertEqual(first.frame.stamp, plan.stamp)
            XCTAssertEqual(pixels(first.frame.image), pixels(f.input.image))
            let next = try f.model.reserveFrame(); next.cancel() // No GPU completion needed to free slot.
        }
    }
    func testBorrowedInputStillCopiesAndSDKInputTransfersOnlyOnce() async throws {
        let f = try await fixture()
        let borrowed = PreparedInput(texture: f.input.texture, source: f.input.source, calibrationID: f.input.calibrationID,
            working: f.input.working, bounds: f.input.valueBounds, qualifications: f.input.qualifications)
        let borrowedPlan = try RenderPlanner().plan(f.controls, input: borrowed, model: f.model)
        let copied = try f.renderer.submit(borrowed, plan: borrowedPlan)
        XCTAssertTrue(copied.usesGPU)
        let copiedResult = try await copied.value()
        XCTAssertFalse(copiedResult.frame.texture === borrowed.texture)
        let direct = try f.renderer.submit(f.input, plan: f.plan())
        XCTAssertFalse(direct.usesGPU)
        _ = try await direct.value()
        let again = try f.renderer.submit(f.input, plan: f.plan())
        XCTAssertTrue(again.usesGPU)
        let againResult = try await again.value()
        XCTAssertFalse(againResult.frame.texture === f.input.texture)
    }
    func testBeforeAcceptCancellationReleasesSlotAndDoesNotPublish() async throws {
        let f = try await fixture(), plan = try f.plan()
        var calls = 0
        XCTAssertThrowsError(try f.renderer.submit(f.input, plan: plan, beforeCommit: {
            calls += 1; throw CancellationError()
        })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(calls, 1)
        let next = try f.model.reserveFrame(); next.cancel()
        XCTAssertThrowsError(try f.renderer.submit(f.input, plan: plan))
    }
    func testObservationsStillExecuteAndMetadataNeedsNoGPU() async throws {
        let f = try await fixture()
        var requirements = ObservationRequirements()
        requirements.features = [.init(id: "mean", statistic: .meanGreen)]
        let gpu = try f.renderer.submit(f.input, plan: f.plan(), observations: requirements)
        XCTAssertTrue(gpu.usesGPU)
        let result = try await gpu.value()
        XCTAssertEqual(result.observations?.features.count, 1)
        XCTAssertNotNil(result.observations?.features.first?.value)
        let direct = try f.renderer.submit(f.input, plan: f.plan(), observations: .init())
        XCTAssertFalse(direct.usesGPU)
        let metadata = try await direct.value()
        XCTAssertEqual(metadata.observations?.captureConditions, f.input.captureConditions)
        XCTAssertEqual(metadata.observations?.features, [])
    }
    func testEDRNeutralOutputPreservesNegativeAndExtendedPixels() async throws {
        let f = try await fixture(range: .edr)
        let submission = try f.renderer.submit(f.input, plan: f.plan())
        XCTAssertFalse(submission.usesGPU)
        let result = try await submission.value()
        XCTAssertEqual(pixels(result.frame.image), pixels(f.input.image))
        XCTAssertLessThan(f.input.valueBounds.lower, 0)
        XCTAssertGreaterThan(f.input.valueBounds.upper, 1)
    }
    func testTextureOnlyAndImageOnlyKeepStorageAliveAndBudgetCharged() async throws {
        for keepImage in [false, true] {
            let f = try await fixture()
            let baseline = try f.model.reserveFrame(); let allowance = baseline.execution.budget.maxResidentBytes; baseline.cancel()
            weak var weakLease: FrameBudgetLease?
            var output: AnyObject?
            // The autorelease pool must also cover the CIImage construction, while the
            // submission retains the published frame until its result is extracted.
            var submission: ModelFrameSubmission? = try autoreleasepool {
                let plan = try f.plan(); weakLease = plan.lease
                return try f.renderer.submit(f.input, plan: plan)
            }
            func takeOutput() async throws -> AnyObject {
                let result = try await submission!.value()
                return keepImage ? result.frame.image : result.frame.texture!
            }
            output = try await takeOutput(); submission = nil
            let retained = try f.model.reserveFrame()
            XCTAssertEqual(retained.execution.budget.maxResidentBytes, allowance - f.input.residentStorageBytes)
            retained.cancel(); XCTAssertNotNil(weakLease)
            withExtendedLifetime(output) {}
            output = nil
            // f.input also owns the delivered texture. Drop it in the next test to prove release.
        }
    }
    func testTransferredLeaseDoesNotFormTextureCycle() async throws {
        var f: Fixture? = try await fixture()
        let model = f!.model
        weak var lease: FrameBudgetLease?
        var submission: ModelFrameSubmission? = try autoreleasepool {
            let plan = try f!.plan(); lease = plan.lease
            return try f!.renderer.submit(f!.input, plan: plan)
        }
        var result: ModelFrameResult? = try await submission!.value()
        let bytes = f!.input.residentStorageBytes
        let allowance = model.execution.budget.maxResidentBytes
        var texture: MTLTexture? = result!.frame.texture
        result = nil; submission = nil; f = nil
        XCTAssertNotNil(lease)
        let retained = try model.reserveFrame()
        XCTAssertEqual(retained.execution.budget.maxResidentBytes, allowance - bytes); retained.cancel()
        withExtendedLifetime(texture) {}
        texture = nil
        XCTAssertNil(lease, "Texture association must never retain a plan or input owning that texture")
        let released = try model.reserveFrame()
        XCTAssertEqual(released.execution.budget.maxResidentBytes, allowance); released.cancel()
    }
}
