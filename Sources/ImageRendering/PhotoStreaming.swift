import Foundation
import CoreImage
import Metal
import ImagingCore

/// Borrowed GPU readback. Bytes remain valid only until the awaited sink returns.
/// Rows follow the renderer's lower-left global image coordinate system.
public struct PhotoTile: @unchecked Sendable {
    public let core: CGRect
    public let bytesPerRow: Int
    public let format: MTLPixelFormat
    public let colorSpace: CGColorSpace
    public let bytes: UnsafeRawBufferPointer
}

public struct PhotoStreamResult: Sendable {
    public let observations: FrameObservations
    public let controls: ResolvedControls
    public let inputFacts: FrameInputFacts
    /// Conservative ceiling for the complete shared model ledger: base/calibration/variant
    /// resources, retained results, source backing and all concurrent frame slots. Concurrent
    /// exports sharing that ledger report the same ceiling; do not add their values together.
    /// Independent model ledgers/caller outputs and opaque CI/decoder backing are outside scope.
    /// This is a declared reservation ceiling, not process RSS or a measured allocation peak.
    public let peakKnownOwnedBytes: Int
    public let hasOpaqueDecoderMemory: Bool
}

extension LumeraRenderer {
    /// Observe the original precision pixels, resolve controls once, and await each output tile.
    /// The sink must copy bytes if it needs to retain them. No complete output allocation is made.
    /// Entry clears idle renderer caches and rejects outstanding pooled commands. While active,
    /// unbudgeted pooled encoding on this renderer rejects; concurrent bounded streams are allowed.
    /// Use a separate renderer for simultaneous legacy unbudgeted rendering.
    public func streamPhoto(_ source: any PhotoRegionSource, model: PreparedCameraModel,
                            calibration: InputCalibration? = nil, inputResources: ModelResourceSet? = nil,
                            edits: EditRequest = .init(), stamp: FrameStamp,
                            targetConditions: CaptureConditions = .init(), seed: UInt32 = 42,
                            region: CGRect? = nil, sink: (PhotoTile) async throws -> Void) async throws -> PhotoStreamResult {
        try await streamPhoto(source, model: model, calibration: calibration, inputResources: inputResources,
            edits: edits, stamp: stamp, targetConditions: targetConditions, seed: seed, region: region,
            reusing: nil, automatic: nil, sink: sink)
    }
    /// Unchecked replay is package-only: PhotoProcessor supplies its source-bound snapshot.
    package func streamPhoto(_ source: any PhotoRegionSource, model: PreparedCameraModel,
                            calibration: InputCalibration? = nil, inputResources: ModelResourceSet? = nil,
                            edits: EditRequest = .init(), stamp: FrameStamp,
                            targetConditions: CaptureConditions = .init(), seed: UInt32 = 42,
                            region: CGRect? = nil, reusing previous: FrameObservations?, automatic priorAutomatic: AutomaticControls?,
                            sink: (PhotoTile) async throws -> Void) async throws -> PhotoStreamResult {
        try Task.checkCancellation()
        let isolation = try encoder.beginBoundedPhotoWork(); defer { isolation.finish() }
        let inputResources = try inputResources ?? ModelResourceSet()
        guard model.renderer === self, source.memory.knownResidentBytes >= 0 else { throw LabError.invalid("Source or model mismatch") }
        let normalizer = try model.prepareInputNormalizer(calibration: calibration, resources: inputResources)
        let lease = try model.budget.acquire(retainedInputBytes: 0, streaming: true)
        defer { lease.completeGPU() }
        let available = lease.allowance - source.memory.knownResidentBytes
        guard available > 1024 * 1024 else { throw LabError.invalid("Source leaves no tile workspace") }
        var execution = model.execution; execution.budget.maxResidentBytes = lease.allowance; execution.budget.maxInFlightFrames = 1
        let observations: FrameObservations
        if let previous {
            guard previous.stamp == stamp, previous.featureDigest == (try model.compiled.definition.observations.featureDigest()) else { throw LabError.invalid("Incompatible reused observations") }
            observations = previous
        } else { observations = try await observe(source, normalizer: normalizer, calibration: calibration, resources: inputResources,
            execution: execution, stamp: stamp, requirements: model.compiled.definition.observations) }
        let automatic = try priorAutomatic ?? CameraModelEvaluator.evaluate(model.compiled, context: .init(evaluationStamp: stamp, observations: observations, targetConditions: targetConditions))
        guard automatic.sourceID == observations.sourceID, automatic.calibrationID == observations.calibrationID else {
            throw LabError.invalid("Automatic controls differ from observation provenance")
        }
        let controls = try EditResolver.resolve(edits, automatic: automatic, model: model.compiled)
        let ratio = min(1, Double(max(execution.width, execution.height)) / Double(max(source.width, source.height)))
        guard max(1, Int(Double(source.width) * ratio)) == execution.width,
              max(1, Int(Double(source.height) * ratio)) == execution.height else { throw LabError.invalid("Output aspect ratio differs from source") }
        let active = controls.lutWeights.filter { $0.weight > 0 }
        let selected = try active.map { weight -> PreparedCameraStyle in
            guard let style = model.lutStyles[weight.resourceID] else { throw LabError.invalid("LUT outside model palette") }; return style
        }
        let style = try active.isEmpty ? model.base : encoder.blendStyle(base: model.base, styles: selected, weights: active.map(\.weight))
        var color = ColorResponse(); color.exposureEV = controls.inputExposureEV
        if let wb = controls.inputWhiteBalance { color.whiteBalance = wb }
        let prefix = try PreparedDeviceCorrection.inputEdit(color, device: device)
        var options = RenderOptions(maximumLongEdge: max(execution.width, execution.height), seed: seed, frameIndex: UInt32(truncatingIfNeeded: stamp.index))
        options.dynamicRange = execution.dynamicRange == .edr ? .edr : .sdr
        let effects = try execution.effectResolutions()
        options.glowScale = effects.glow; options.halationScale = effects.halation; options.softeningScale = effects.softening; options.previewGlow = execution.previewGlow
        let parameters = controls.parameters
        // Input preparation and calibration have a disjoint half of the tile allowance.
        let planner = try TilePlanner(width: source.width, height: source.height, style: parameters, options: options, budget: available / 2,
            preparedGrain: parameters.grain.isActive ? style.executionPlan.grain(for: parameters.grain) : nil)
        let frame = CGRect(x: 0, y: 0, width: execution.width, height: execution.height), roi = region ?? frame
        guard !roi.isEmpty, roi == roi.integral, frame.contains(roi) else { throw LabError.invalid("Invalid output region") }
        var facts: FrameInputFacts?
        try await planner.forEachTile(region: roi) { tile in
            guard planner.fits(tile) else { throw TileAllocationLimit() }
            var local = execution; local.budget.maxResidentBytes = available / 2
            let normalized = try await source.prepare(region: tile.sourceArea, execution: local)
            let input = try await normalizer.normalize(normalized, calibration: calibration, resources: inputResources, bounded: true)
            guard input.width == Int(tile.sourceArea.width), input.height == Int(tile.sourceArea.height),
                  input.sourceID == observations.sourceID, input.calibrationID == observations.calibrationID else { throw LabError.invalid("Region provider changed source facts") }
            facts = try input.photoFacts(stamp: stamp)
            let compatibility = model.compiled.definition.compatibility
            guard compatibility.referenceRenditionIDs.isEmpty || compatibility.referenceRenditionIDs.contains(input.working.referenceRenditionID),
                  Set(compatibility.requiredQualifications).isSubset(of: Set(input.qualifications.map(\.domain))) else { throw LabError.invalid("Input incompatible with model") }
            let workspace = TileWorkingSet(limit: available / 2)
            try workspace.reserve(input.residentStorageBytes)
            let geometry = RenderGeometry(fullWidth: planner.fullWidth, fullHeight: planner.fullHeight, area: tile.area,
                sourceWidth: planner.sourceWidth, sourceHeight: planner.sourceHeight, sourceArea: tile.sourceArea)
            var request = options.makeRequest(input: .init(width: input.width, height: input.height)); request.inputValueBounds = input.valueBounds
            try self.encoder.checkModelSafety(style: style, parameters: parameters, prefix: prefix, request: request, geometry: geometry)
            guard let command = self.queue.makeCommandBuffer() else { throw LabError.io("Cannot create tile command") }
            let output = try self.encoder.encodeModel(input.texture, style: style, parameters: parameters, prefix: prefix,
                request: request, workingSet: workspace, geometry: geometry, commandBuffer: command)
            let bpp = execution.precision.bytesPerPixel, w = Int(tile.core.width), h = Int(tile.core.height)
            let stride = ((w * bpp + 255) / 256) * 256
            try workspace.reserve(bufferLength: stride * h, on: self.device)
            guard let buffer = self.device.makeBuffer(length: stride * h, options: .storageModeShared), let blit = command.makeBlitCommandEncoder() else { throw LabError.io("Cannot allocate readback") }
            blit.copy(from: output, sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: .init(x: Int(tile.core.minX - tile.area.minX), y: Int(tile.core.minY - tile.area.minY), z: 0),
                sourceSize: .init(width: w, height: h, depth: 1), to: buffer, destinationOffset: 0, destinationBytesPerRow: stride, destinationBytesPerImage: stride * h)
            blit.endEncoding(); try await self.complete(command)
            try Task.checkCancellation()
            try await sink(PhotoTile(core: tile.core, bytesPerRow: stride, format: self.imageInputFormat,
                colorSpace: Self.colorSpace(for: options.dynamicRange), bytes: .init(start: buffer.contents(), count: stride * h)))
            withExtendedLifetime(buffer) {}
        }
        return PhotoStreamResult(observations: observations, controls: controls, inputFacts: facts!, peakKnownOwnedBytes: model.execution.budget.maxResidentBytes, hasOpaqueDecoderMemory: source.memory.hasOpaqueDecoderMemory)
    }
}
