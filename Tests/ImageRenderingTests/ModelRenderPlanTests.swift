import XCTest
import CoreImage
import Metal
import ImagingCore
@testable import ImageRendering

final class ModelRenderPlanTests: XCTestCase {
    func testStaticConfigurationRebindsCurrentFrameAndInvalidatesEdits() async throws {
        let renderer = try LumeraRenderer(), firstInput = try await input(renderer)
        let compiled = try StyleModelCompiler.compile(model())
        let prepared = try ModelPreparer(renderer: renderer).prepare(compiled, resources: .init(), execution: execution())
        var values = controls(compiled, input: firstInput)
        values.parameters.color.exposureEV = 0.5
        let first = try RenderPlanner().plan(values, input: firstInput, model: prepared, seed: 7)
        let configuration = first.configuration
        first.cancel()
        let nextInput = try await input(renderer)
        let next = try RenderPlanner().plan(values, input: nextInput, model: prepared, seed: 42)
        XCTAssertTrue(configuration === next.configuration)
        XCTAssertTrue(next.input === nextInput)
        XCTAssertEqual(next.request.seed, 42)
        XCTAssertEqual(next.request.inputValueBounds, nextInput.valueBounds)
        XCTAssertFalse(first.lease === next.lease)
        next.cancel()
        values.inputExposureEV = 1
        let changed = try RenderPlanner().plan(values, input: nextInput, model: prepared)
        XCTAssertFalse(configuration === changed.configuration)
        XCTAssertNotNil(changed.prefix)
        changed.cancel()
        values.inputExposureEV = 0
        values.parameters.grain.enabled = true; values.parameters.grain.amount = 0.01
        let grain = try RenderPlanner().plan(values, input: nextInput, model: prepared)
        XCTAssertFalse(configuration === grain.configuration)
        XCTAssertNil(grain.prefix)
        grain.cancel()
    }

    func testDisabledNoiseDoesNotUploadUnusedLargeCurve() async throws {
        let renderer = try LumeraRenderer(), input = try await input(renderer)
        let compiled = try StyleModelCompiler.compile(model())
        let prepared = try ModelPreparer(renderer: renderer).prepare(compiled, resources: .init(), execution: execution())
        var values = controls(compiled, input: input)
        values.parameters.color.exposureEV = 1
        values.parameters.noise.enabled = false
        values.parameters.noise.curve = .init(knots: (0..<400).map { .init(x: Double($0) / 399, y: 0.01) })
        let plan = try RenderPlanner().plan(values, input: input, model: prepared)
        let result = try await renderer.submit(input, plan: plan).value()
        var pixels = [Float](repeating: 0, count: 16)
        pixels.withUnsafeMutableBytes { CIContext().render(result.frame.image, toBitmap: $0.baseAddress!, rowBytes: 32,
            bounds: result.frame.image.extent, format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) }
        XCTAssertEqual(pixels[0], 0.6858, accuracy: 0.004)
    }

    func testResourceStorageRejectsUnrepresentableDimensionBeforeBudgetArithmetic() throws {
        var definition = model()
        definition.appearance.resources = [.init(id: "curve", sha256: String(repeating: "a", count: 64), dimension: Int.max)]
        definition.appearance.resources[0].role = .toneCurve
        let renderer = try LumeraRenderer()
        let compiled = try StyleModelCompiler.compile(definition)
        let resources = try ModelResourceSet(curves: ["curve": .identity])
        XCTAssertThrowsError(try ModelPreparer(renderer: renderer).prepare(compiled, resources: resources, execution: execution()))
    }

    func testOversizedActiveCurveRejectsAtUniformUpload() async throws {
        let renderer = try LumeraRenderer(), input = try await input(renderer)
        let compiled = try StyleModelCompiler.compile(model())
        let prepared = try ModelPreparer(renderer: renderer).prepare(compiled, resources: .init(), execution: execution())
        var values = controls(compiled, input: input)
        values.parameters.tone.enabled = true
        values.parameters.tone.curve = .init(knots: (0..<400).map { .init(x: Double($0) / 399, y: Double($0) / 798) })
        let plan = try RenderPlanner().plan(values, input: input, model: prepared)
        let command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
        XCTAssertThrowsError(try FrameEncoder(renderer: renderer).encode(input, plan: plan, commandBuffer: command))
    }

    func testEmptyAndSingletonToneCurvesMatchCPUSampling() async throws {
        let renderer = try LumeraRenderer(), input = try await input(renderer)
        let compiled = try StyleModelCompiler.compile(model())
        let prepared = try ModelPreparer(renderer: renderer).prepare(compiled, resources: .init(), execution: execution())
        for (knots, expected) in [([ResponseKnot](), Float(0)), ([ResponseKnot(x: 0.5, y: 0.25)], Float(0.25))] {
            var values = controls(compiled, input: input)
            values.parameters.tone.enabled = true; values.parameters.tone.curve = .init(knots: knots)
            let plan = try RenderPlanner().plan(values, input: input, model: prepared)
            let result = try await renderer.submit(input, plan: plan).value()
            var pixels = [Float](repeating: 0, count: 16)
            pixels.withUnsafeMutableBytes { CIContext().render(result.frame.image, toBitmap: $0.baseAddress!, rowBytes: 32,
                bounds: result.frame.image.extent, format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) }
            XCTAssertEqual(pixels[0], expected, accuracy: 0.004)
        }
    }

    func testGlowTileSupportUsesBothConsumedBlurRadii() throws {
        var parameters = StyleParameters()
        parameters.glow.enabled = true; parameters.glow.amount = 0.1
        parameters.glow.nearSigma = 40; parameters.glow.farSigma = 1
        let planner = try TilePlanner(width: 2048, height: 2048, style: parameters,
            options: .init(), budget: 256 * 1024 * 1024, preparedGrain: nil)
        XCTAssertEqual(planner.halo, 121)
    }

    func testGrainPreparationHandlesItsOwnArithmeticDomain() throws {
        var grain = FilmGrain(); grain.enabled = true; grain.amount = 0.01; grain.roughness = 2
        XCTAssertThrowsError(try EffectUniforms.grain(grain, scale: 1, seed: 42))
    }

    func testColorPreparationAcceptsExecutableValuesOutsideDiagnosticRange() throws {
        var color = ColorResponse(); color.matrix.values[0] = 5
        XCTAssertThrowsError(try color.validate())
        XCTAssertEqual(try ColorTransform.prepare(color).apply([0.1, 0.2, 0.3])[0], 0.5, accuracy: 1e-12)
        color.matrix.values = [1, 0]
        XCTAssertThrowsError(try ColorTransform.prepare(color))
    }
    func testUnusedParameterDiagnosticsDoNotBlockPlanningOrSubmission() async throws {
        let renderer = try LumeraRenderer(), input = try await input(renderer)
        let compiled = try StyleModelCompiler.compile(model())
        let prepared = try ModelPreparer(renderer: renderer).prepare(compiled, resources: .init(), execution: execution())
        var values = controls(compiled, input: input)
        values.parameters.grain.enabled = false
        values.parameters.grain.roughness = 2
        values.parameters.color.exposureEV = 1
        XCTAssertThrowsError(try values.parameters.validate(resolved: true))
        let plan = try RenderPlanner().plan(values, input: input, model: prepared)
        let request = try PreparedProcessingRequest(plan: plan)
        let resources = ProcessingResources(device: renderer.device)
        guard case .ready = resources.prepare(request), case .ready(let frame) = resources.acquireFrame(for: request) else {
            return XCTFail("Could not prepare frame resources")
        }
        let result = try await renderer.submit(input, plan: plan, output: frame.outputTexture,
            workspace: frame.workspace, request: request).value()
        var pixels = [Float](repeating: 0, count: 16)
        pixels.withUnsafeMutableBytes { CIContext().render(result.frame.image, toBitmap: $0.baseAddress!, rowBytes: 32,
            bounds: result.frame.image.extent, format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) }
        XCTAssertEqual(pixels[0], 0.6858, accuracy: 0.004)
        XCTAssertEqual(result.frame.resolvedControls.parameters.grain.roughness, 2)
    }
    func execution(bytes: Int = 32 * 1024 * 1024) -> ExecutionProfile {
        .init(width: 2, height: 2, budget: .init(maxInFlightFrames: 1, maxResidentBytes: bytes))
    }
    func model() -> StyleModel { .init(identity: .init(id: "fixture", name: "test")) }
    func input(_ renderer: LumeraRenderer, execution: ExecutionProfile? = nil) async throws -> PreparedInput {
        var descriptor = SourceDescriptor(id: "input", path: .processedPhoto); descriptor.recipeID = "ci"
        let image = CIImage(color: .init(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: .init(x: 0, y: 0, width: 2, height: 2))
        let normalized = try await InputAdapter(renderer: renderer, working: .init(referenceRenditionID: "fixture")).prepare(.image(image), descriptor: descriptor,
            recipe: .init(id: "ci", backend: "coreImage", version: "1", decodedRendition: .baseImage), execution: execution ?? self.execution())
        return try await InputNormalizer(renderer: renderer).normalize(normalized, calibration: nil, resources: .init())
    }
    func controls(_ model: CompiledStyleModel, input: PreparedInput) -> ResolvedControls {
        let automatic = AutomaticControls(parameters: model.definition.appearance.parameters, modelID: model.identity, sourceID: input.sourceID, calibrationID: input.calibrationID, featureDigest: model.featureDigest)
        return .init(automatic: automatic, parameters: automatic.parameters, lutWeights: [])
    }
    func testMissingAssetWrongDigestAndBudgetRejectPreparation() throws {
        let renderer = try LumeraRenderer(), preparer = ModelPreparer(renderer: renderer)
        var definition = model()
        definition.appearance.resources = [.init(id: "missing", sha256: String(repeating: "a", count: 64), dimension: 2)]
        XCTAssertThrowsError(try preparer.prepare(StyleModelCompiler.compile(definition), resources: .init(), execution: execution()))
        XCTAssertThrowsError(try preparer.prepare(StyleModelCompiler.compile(model()), resources: .init(), execution: execution(bytes: 1)))
    }
    func testInputEditsPrecedeTargetTransformAndPlanRejectsForeignInput() async throws {
        let renderer = try LumeraRenderer(), preparedInput = try await input(renderer)
        var definition = model(); definition.appearance.parameters.tone.enabled = true
        definition.appearance.parameters.tone.curve = .init(function: .init(family: .power))
        let compiled = try StyleModelCompiler.compile(definition)
        let prepared = try ModelPreparer(renderer: renderer).prepare(compiled, resources: .init(), execution: execution())
        var values = controls(compiled, input: preparedInput); values.inputExposureEV = 1
        let plan = try RenderPlanner().plan(values, input: preparedInput, model: prepared)
        let command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
        let encoded = try FrameEncoder(renderer: renderer).encode(preparedInput, plan: plan, commandBuffer: command)
        XCTAssertEqual(command.status, .notEnqueued)
        let owned = try encoded.copyOwned(commandBuffer: command)
        XCTAssertThrowsError(try owned.resolve())
        try await renderer.complete(command)
        let result = try owned.resolve()
        XCTAssertEqual(result.resolvedControls, values)
        var pixels = [Float](repeating: 0, count: 16)
        pixels.withUnsafeMutableBytes { CIContext().render(result.image, toBitmap: $0.baseAddress!, rowBytes: 32, bounds: result.image.extent, format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) }
        let linear = pow((0.5 + 0.055) / 1.055, 2.4)
        let exposed = 1.055 * pow(2 * linear, 1 / 2.4) - 0.055
        XCTAssertEqual(Double(pixels[0]), exposed * exposed, accuracy: 0.004)
        let nextPlan = try RenderPlanner().plan(values, input: preparedInput, model: prepared)
        withExtendedLifetime(nextPlan) {}
        let other = try await input(renderer), next = try XCTUnwrap(renderer.queue.makeCommandBuffer())
        XCTAssertThrowsError(try FrameEncoder(renderer: renderer).encode(other, plan: plan, commandBuffer: next))
    }
    func testConditionalEffectIsPreparedBeforeActivationAndNoBudgetOvercommit() async throws {
        let renderer = try LumeraRenderer(), input = try await input(renderer)
        var definition = model(); definition.appearance.parameters.halation.enabled = true; definition.appearance.parameters.halation.amount = 0
        definition.observations.sourceConditions = [.iso]
        definition.responses = [.init(target: "halation.amount", expression: .singleAxis(axis: .source(.iso), nodes: [.init(100, .scalar(0)), .init(800, .scalar(0.2))], boundary: .clamp))]
        let compiled = try StyleModelCompiler.compile(definition)
        let prepared = try ModelPreparer(renderer: renderer).prepare(compiled, resources: .init(), execution: execution())
        XCTAssertGreaterThan(prepared.preparationStatistics.halations, 0)
        let first = try RenderPlanner().plan(controls(compiled, input: input), input: input, model: prepared)
        XCTAssertThrowsError(try RenderPlanner().plan(controls(compiled, input: input), input: input, model: prepared))
        withExtendedLifetime(first) {}
    }
    func testInvalidCommandDoesNotConsumePlanAndTimingSurvives() async throws {
        let renderer = try LumeraRenderer(), input = try await input(renderer)
        let compiled = try StyleModelCompiler.compile(model())
        let prepared = try ModelPreparer(renderer: renderer).prepare(compiled, resources: .init(), execution: execution())
        let stamp = FrameStamp(streamID: "camera", generation: 2, index: UInt64(UInt32.max) + 5, presentationTime: 3.5, duration: 0.02)
        let plan = try RenderPlanner().plan(controls(compiled, input: input), input: input, model: prepared, stamp: stamp)
        let completed = try XCTUnwrap(renderer.queue.makeCommandBuffer()); try await renderer.complete(completed)
        XCTAssertThrowsError(try FrameEncoder(renderer: renderer).encode(input, plan: plan, commandBuffer: completed))
        let command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
        let encoded = try FrameEncoder(renderer: renderer).encode(input, plan: plan, commandBuffer: command)
        let ticket = try encoded.copyOwned(commandBuffer: command); try await renderer.complete(command)
        XCTAssertEqual(try ticket.resolve().stamp, stamp)
    }
    func testExecutionGeometryAndComputationalScaleAreExplicit() async throws {
        let renderer = try LumeraRenderer(), input = try await input(renderer)
        let compiled = try StyleModelCompiler.compile(model())
        var e = execution(); e.effectScale = 0.5
        let prepared = try ModelPreparer(renderer: renderer).prepare(compiled, resources: .init(), execution: e)
        let plan = try RenderPlanner().plan(controls(compiled, input: input), input: input, model: prepared)
        XCTAssertEqual(plan.request.halationScale, .half)
        XCTAssertEqual(plan.controls.parameters.halation.radius, compiled.definition.appearance.parameters.halation.radius)
        var wrong = execution(); wrong.height = 1
        let mismatch = try ModelPreparer(renderer: renderer).prepare(compiled, resources: .init(), execution: wrong)
        XCTAssertThrowsError(try RenderPlanner().plan(controls(compiled, input: input), input: input, model: mismatch))
    }

    func testPreparationReservationIsSingleUseAndCanBeCancelled() async throws {
        let renderer = try LumeraRenderer(), input = try await input(renderer)
        let compiled = try StyleModelCompiler.compile(model())
        let prepared = try ModelPreparer(renderer: renderer).prepare(compiled, resources: .init(), execution: execution())
        let cancelled = try prepared.reserveFrame()
        XCTAssertThrowsError(try prepared.reserveFrame())
        cancelled.cancel()
        let reservation = try prepared.reserveFrame()
        let plan = try RenderPlanner().plan(controls(compiled, input: input), input: input, model: prepared, reservation: reservation)
        XCTAssertThrowsError(try RenderPlanner().plan(controls(compiled, input: input), input: input, model: prepared, reservation: reservation))
        plan.cancel()
        let next = try prepared.reserveFrame(); next.cancel()
    }
    func testEscapedOutputImageRetainsMemoryReservation() async throws {
        let renderer = try LumeraRenderer(), input = try await input(renderer)
        let compiled = try StyleModelCompiler.compile(model())
        let prepared = try ModelPreparer(renderer: renderer).prepare(compiled, resources: .init(), execution: execution())
        func renderImage() async throws -> CIImage {
            let plan = try RenderPlanner().plan(controls(compiled, input: input), input: input, model: prepared)
            let command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
            let encoded = try FrameEncoder(renderer: renderer).encode(input, plan: plan, commandBuffer: command)
            let ticket = try encoded.copyOwned(commandBuffer: command); try await renderer.complete(command)
            return try ticket.resolve().image
        }
        let image = try await renderImage()
        let next = try prepared.reserveFrame()
        XCTAssertLessThan(next.execution.budget.maxResidentBytes, execution().budget.maxResidentBytes)
        withExtendedLifetime(image) {}; next.cancel()
    }

    func testPrecisionRejectionBeforeEncodingCanReleaseReservation() async throws {
        let renderer = try LumeraRenderer(), input = try await input(renderer)
        let compiled = try StyleModelCompiler.compile(model())
        let prepared = try ModelPreparer(renderer: renderer).prepare(compiled, resources: .init(), execution: execution())
        var values = controls(compiled, input: input); values.inputExposureEV = 10; values.parameters.color.exposureEV = 10
        // A real optical stage is required: encoded-only output no longer stores
        // the large decoded value that this pre-encoding rejection fixture targets.
        values.parameters.vignette.enabled = true; values.parameters.vignette.amountEV = 1
        let plan = try RenderPlanner().plan(values, input: input, model: prepared)
        let command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
        XCTAssertThrowsError(try FrameEncoder(renderer: renderer).encode(input, plan: plan, commandBuffer: command))
        plan.cancel()
        let next = try prepared.reserveFrame(); next.cancel()
    }

    func testRepeatedTiledPlanRejectsWithoutIncreasingWorkingSet() async throws {
        let renderer = try LumeraRenderer(), input = try await input(renderer)
        let compiled = try StyleModelCompiler.compile(model())
        let prepared = try ModelPreparer(renderer:renderer).prepare(compiled,resources:.init(),execution:execution())
        let plan = try RenderPlanner().plan(controls(compiled,input:input),input:input,model:prepared)
        let output = try await renderer.renderTiled(input,plan:plan)
        let bytesAfterFirst = plan.workingSet.bytes
        do { _ = try await renderer.renderTiled(input,plan:plan); XCTFail("Single-use tiled plan reused") } catch { }
        XCTAssertEqual(plan.workingSet.bytes,bytesAfterFirst)
        XCTAssertEqual(output.width,2)
        withExtendedLifetime(output) {}
    }
    func testBeforeCommitFailureReleasesActiveSlotWhilePlanIsRetained() async throws {
        enum CancellationAtCommit: Error { case injected }
        let renderer = try LumeraRenderer(), input = try await input(renderer)
        let compiled = try StyleModelCompiler.compile(model())
        let prepared = try ModelPreparer(renderer:renderer).prepare(compiled,resources:.init(),execution:execution())
        let plan = try RenderPlanner().plan(controls(compiled,input:input),input:input,model:prepared)
        var called = false
        XCTAssertThrowsError(try renderer.submit(input,plan:plan,beforeCommit:{ called = true; throw CancellationAtCommit.injected })) { error in
            guard case CancellationAtCommit.injected = error else { return XCTFail("Failure did not reach final commit hook: \(error)") }
        }
        XCTAssertTrue(called)
        let retainedInput = input.residentStorageBytes
        let next = try prepared.reserveFrame()
        XCTAssertEqual(next.execution.budget.maxResidentBytes,plan.lease.allowance - retainedInput,
                       "Aborted unpublished output must not remain charged while the failed plan is retained")
        next.cancel()
        // Releasing the plan must not be needed to recover its active GPU slot.
        withExtendedLifetime(plan) {}
        XCTAssertThrowsError(try renderer.submit(input,plan:plan))
    }
    func testAsyncOwnedRenderHonorsCancellationAfterEncodingStarts() async throws {
        let renderer = try LumeraRenderer(), input = try await input(renderer)
        let compiled = try StyleModelCompiler.compile(model())
        let prepared = try ModelPreparer(renderer: renderer).prepare(compiled, resources: .init(), execution: execution())
        let plan = try RenderPlanner().plan(controls(compiled, input: input), input: input, model: prepared)
        let event = try XCTUnwrap(renderer.device.makeSharedEvent()), blocker = try XCTUnwrap(renderer.queue.makeCommandBuffer())
        blocker.encodeWaitForEvent(event, value: 1); blocker.commit()
        let task = Task { try await renderer.render(input, plan: plan) }
        for _ in 0..<10000 {
            if plan.hasBeenClaimed { break }
            await Task.yield()
        }
        XCTAssertTrue(plan.hasBeenClaimed, "Render never began encoding")
        task.cancel(); event.signaledValue = 1
        do { _ = try await task.value; XCTFail("Cancelled owned render returned a successful frame") }
        catch { XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)") }
    }

    func testFailedTiledOutputDoesNotRetainUnpublishedImageCharge() async throws {
        let renderer = try LumeraRenderer(), input = try await input(renderer)
        let compiled = try StyleModelCompiler.compile(model())
        let prepared = try ModelPreparer(renderer: renderer).prepare(compiled, resources: .init(), execution: execution())
        let plan = try RenderPlanner().plan(controls(compiled, input: input), input: input, model: prepared)
        let initialAllowance = plan.workingSet.limit
        let outputBytes = 2 * 2 * ExecutionPrecision.float16.bytesPerPixel
        try plan.workingSet.reserve(initialAllowance - plan.workingSet.bytes - outputBytes)
        do { _ = try await renderer.renderTiled(input, plan: plan); XCTFail("No tile workspace should reject") } catch { }
        let next = try prepared.reserveFrame(); defer { next.cancel() }
        XCTAssertEqual(next.execution.budget.maxResidentBytes, initialAllowance - input.residentStorageBytes)
        withExtendedLifetime(plan) {}
    }

}

extension ModelRenderPlanTests {
    func testLegacyExecutionDecodesSharedScaleAndEnabledGlow() throws {
        let legacy = Data("""
            {"precision":"float16","width":2,"height":2,"dynamicRange":"sdr","effectScale":0.5,
             "statisticsLatency":{"sameFrame":{}},"budget":{"maxInFlightFrames":1,"maxResidentBytes":33554432}}
            """.utf8)
        let value = try JSONDecoder().decode(ExecutionProfile.self, from: legacy)
        XCTAssertEqual(try value.effectResolutions().glow, .half)
        XCTAssertEqual(try value.effectResolutions().halation, .half)
        XCTAssertEqual(try value.effectResolutions().softening, .half)
        XCTAssertTrue(value.previewGlow)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSON.encode(value)) as? NSDictionary)
        XCTAssertEqual(encoded, try JSONSerialization.jsonObject(with: legacy) as? NSDictionary)
    }

    func testExecutionEffectsReachRenderPlanAndOverrideLegacyFallback() async throws {
        let renderer = try LumeraRenderer(), input = try await input(renderer)
        let compiled = try StyleModelCompiler.compile(model())
        var e = execution(); e.effectScale = 0.5
        e.glowScale = .quarter; e.softeningScale = .eighth; e.previewGlow = false
        let prepared = try ModelPreparer(renderer: renderer).prepare(compiled, resources: .init(), execution: e)
        let plan = try RenderPlanner().plan(controls(compiled, input: input), input: input, model: prepared)
        XCTAssertEqual(plan.request.glowScale, .quarter)
        XCTAssertEqual(plan.request.halationScale, .half)
        XCTAssertEqual(plan.request.softeningScale, .eighth)
        XCTAssertFalse(plan.request.previewGlow)
        XCTAssertEqual(try JSONDecoder().decode(ExecutionProfile.self, from: JSONEncoder().encode(e)), e)
    }

    func testStandaloneInputAcceptsLegacyScaleWhileModelRequiresSupportedEffectResolutions() async throws {
        let renderer = try LumeraRenderer(), preparer = ModelPreparer(renderer: renderer)
        let compiled = try StyleModelCompiler.compile(model())
        var execution = self.execution()
        execution.effectScale = 0.75
        let input = try await input(renderer, execution: execution)
        XCTAssertEqual(input.execution.effectScale, 0.75)
        XCTAssertThrowsError(try preparer.prepare(compiled, resources: .init(), execution: execution)) { error in
            guard case LabError.unsupported = error else { return XCTFail("Expected unsupported optical scale, got \(error)") }
        }

        execution.glowScale = .half
        execution.halationScale = .quarter
        execution.softeningScale = .full
        let prepared = try preparer.prepare(compiled, resources: .init(), execution: execution)
        let plan = try RenderPlanner().plan(controls(compiled, input: input), input: input, model: prepared)
        XCTAssertEqual(plan.request.glowScale, .half)
        XCTAssertEqual(plan.request.halationScale, .quarter)
        XCTAssertEqual(plan.request.softeningScale, .full)
    }
}

extension ModelRenderPlanTests {
    func testStreamingPreparationRejectsOverflowingFrameWorkingSet() throws {
        let compiled = try StyleModelCompiler.compile(model())
        for precision in [ExecutionPrecision.float16, .float32] {
            let renderer = try LumeraRenderer(precision: precision == .float16 ? .float16 : .float32)
            let preparer = ModelPreparer(renderer: renderer)
            var valid = execution(); valid.precision = precision
            let original = try preparer.prepareStreaming(compiled, resources: .init(), execution: valid)
            var overflowing = valid
            overflowing.width = 1
            overflowing.height = Int.max / (precision.bytesPerPixel * 4) + 1
            XCTAssertNoThrow(try overflowing.validate(), "Pixel storage fits; only the full working set overflows")
            XCTAssertThrowsError(try preparer.prepareStreaming(compiled, resources: .init(), execution: overflowing)) { error in
                guard case LabError.invalid = error else { return XCTFail("Expected validation error, got \(error)") }
            }
            XCTAssertThrowsError(try preparer.prepareVariant(of: original, execution: overflowing, streaming: true)) { error in
                guard case LabError.invalid = error else { return XCTFail("Expected variant validation error, got \(error)") }
            }
        }
    }
}
