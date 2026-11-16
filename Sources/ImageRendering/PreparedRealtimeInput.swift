import Foundation
import CoreImage
import Metal
import ImagingCore

/// Explicit, reusable input normalization configuration. prepare() may allocate;
/// FrameSource borrows a prepared slot and records work for the next GPU command.
public final class PreparedRealtimeInput: @unchecked Sendable {
    private let resourceCharges: [ProcessingResourceCharge]
    private let adapter: InputAdapter
    private let renderer: LumeraRenderer
    private let descriptor: SourceDescriptor
    private let recipe: InputRecipe
    private let execution: ExecutionProfile
    private let bounds: NumericBounds
    private let calibration: InputCalibration?
    private let calibrationID: String?
    private let request: PreparedProcessingRequest
    public let resources: ProcessingResources

    init(renderer: LumeraRenderer, adapter: InputAdapter, normalizer: InputNormalizer,
         descriptor: SourceDescriptor, recipe: InputRecipe, execution: ExecutionProfile,
         bounds: NumericBounds, observations: ObservationRequirements, calibration: InputCalibration?, modelResources: ModelResourceSet,
         resources: ProcessingResources) throws {
        try bounds.validate()
        self.renderer = renderer; self.adapter = adapter; self.descriptor = descriptor; self.recipe = recipe
        self.execution = execution; self.bounds = bounds; self.calibration = calibration
        self.resources = resources
        let prepared = try normalizer.explicitPreparation(calibration: calibration, resources: modelResources)
        var charges = try (prepared.correction?.lutTexture).map { [try resources.ledger.borrow($0, adaptingPolicy: true)] } ?? []
        charges.append(try resources.ledger.reserve(modelResources.luts.values.reduce(0) { $0 + $1.residentSourceBytes }, adaptingPolicy: true))
        resourceCharges = charges
        calibrationID = prepared.identity
        var options = RenderOptions()
        options.dynamicRange = execution.dynamicRange == .edr ? .edr : .sdr
        options.inputValueBounds = bounds
        request = try PreparedProcessingRequest(renderer: renderer, style: prepared.style,
            input: .init(width: execution.width, height: execution.height), options: options, requiresImageStaging: calibration != nil, observations: observations, correction: prepared.correction)
    }
    public func prepare() -> ProcessingPreparationResult { resources.prepare(request) }

    /// The caller certifies finite normalized RGB within the bounds supplied at configuration.
    /// No range scan is performed. Source backing is retained until its pending render completes.
    /// The returned input must be consumed by a model observation/submission before reading pixels.
    package func makeInput(_ source: SourceImage, context: CIContext) throws -> PreparedInput {
        guard source.inputDevelopment == .decodedPixels else { throw LabError.unsupported("Explicit realtime input requires decoded pixels") }
        let resolved = try adapter.resolve(source, descriptor: descriptor, recipe: recipe, execution: execution)
        guard resolved.width == request.input.width, resolved.height == request.input.height else {
            throw FrameAdmissionIssue.notPrepared
        }
        if let calibration {
            guard calibration.source == resolved.identity.descriptor, calibration.working == resolved.identity.working,
                  calibration.recipeDigest == resolved.identity.recipeDigest else {
                throw LabError.invalid("Input source, effective recipe or reference does not match calibration")
            }
        }
        let sourceCharge: ProcessingResourceCharge?
        if case .pixelBuffer(let buffer, _, _) = source { sourceCharge = try resources.ledger.borrow(buffer) }
        else { sourceCharge = nil }
        let frame: FrameResources
        switch resources.acquireFrame(for: request) {
        case .ready(let value): frame = value
        case .unavailable(let issue): throw issue
        }
        let normalizedTexture = calibration == nil ? frame.outputTexture : (frame.workspace.storage.input?.texture ?? frame.outputTexture)
        let normalized = NormalizedInput(texture: normalizedTexture, properties: resolved.properties, identity: resolved.identity,
            execution: execution, bounds: bounds, conditions: resolved.conditions, inputDevelopment: .decodedPixels, boundsEvidence: .declared)
        let finalBounds: NumericBounds
        if calibration != nil {
            // The existing SDR calibration finish clamps RGB. Extended calibration needs
            // a separately proven output interval and is not silently assigned SDR bounds.
            guard execution.dynamicRange == .sdr else { throw LabError.unsupported("Explicit EDR calibration needs declared output bounds") }
            finalBounds = .init(lower: 0, upper: 1)
        } else { finalBounds = bounds }
        try InputNormalizer.validateBounds(finalBounds, working: normalized.working)
        let input = PreparedInput(texture: frame.outputTexture, source: normalized,
            calibrationID: calibrationID ?? resolved.identity.unqualifiedReferenceID, working: normalized.working,
            bounds: finalBounds, qualifications: calibration?.qualifications.filter { qualification in
                qualification.conditionRanges.allSatisfy { range in resolved.conditions[range.axis].map(range.bounds.contains) ?? false }
            } ?? [], boundsEvidence: calibration == nil ? .declared : .derived)
        let pending = PendingInputEncoding { command in
            _ = ProcessingCommandOwner.attach(to: command, retaining: [frame, resolved, context] + (sourceCharge.map { [$0] } ?? []))
            context.render(resolved.image, to: normalizedTexture, commandBuffer: command, bounds: resolved.bounds,
                           colorSpace: LumeraRenderer.colorSpace(for: self.request.options.dynamicRange))
            if self.calibration != nil {
                guard frame.workspace.claim(for: self.request) else { throw FrameAdmissionIssue.incompatibleResources }
                try self.renderer.encoder.encodePrepared(normalizedTexture, output: frame.outputTexture,
                    prepared: self.request, arena: frame.workspace.storage.arena, command: command)
            }
        }
        input.pendingEncoding = pending
        input.observationWorkspace = frame.workspace.storage.observations
        input.processingRetention = calibration == nil && input.observationWorkspace == nil ? nil : frame
        return input
    }
}

final class PendingInputEncoding: @unchecked Sendable {
    private let lock = UnfairLock()
    private var encode: ((MTLCommandBuffer) throws -> Void)?
    private var failed = false
    private weak var encodedCommand: MTLCommandBuffer?
    private var completed = false
    init(_ encode: @escaping (MTLCommandBuffer) throws -> Void) { self.encode = encode }
    func encodeOnce(_ command: MTLCommandBuffer) throws {
        let work = try lock.withLock { () throws -> ((MTLCommandBuffer) throws -> Void)? in
            guard !failed else { throw LabError.invalid("Input preparation previously failed") }
            if encode == nil {
                guard completed || encodedCommand === command else { throw FrameAdmissionIssue.busy }
                return nil
            }
            encodedCommand = command
            command.addCompletedHandler { [self] done in
                lock.withLock { completed = true; failed = done.status != .completed || done.error != nil }
            }
            let work = encode; encode = nil; return work
        }
        do { try work?(command) }
        catch { lock.withLock { failed = true }; throw error }
    }
}
