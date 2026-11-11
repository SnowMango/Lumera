import ImagingCore

/// Reusable, model-bound configuration for source preparation after frame admission.
public final class RealtimeInputPreparer: Sendable {
    package let model: PreparedStyleModel
    private let adapter: InputAdapter
    private let normalizer: InputNormalizer
    private let calibration: InputCalibration?
    private let resources: ModelResourceSet

    init(model: PreparedStyleModel, working: WorkingImageContract, calibration: InputCalibration?, resources: ModelResourceSet) throws {
        self.model = model; self.calibration = calibration
        let selected = Set(calibration?.resources.map(\.id) ?? [])
        self.resources = try ModelResourceSet(luts: resources.luts.filter { selected.contains($0.key) })
        adapter = try InputAdapter(renderer: model.renderer, working: working)
        let scope = try model.renderer.encoder.beginBoundedPhotoWork(); defer { scope.finish() }
        normalizer = try model.prepareInputNormalizer(calibration: calibration, resources: self.resources)
    }

    package func prepare(_ source: SourceImage, descriptor: SourceDescriptor, recipe: InputRecipe,
                         execution: ExecutionProfile, rawOverrides: [RAWOverride],
                         rawConfiguration: RAWDevelopmentConfiguration?, trustedNormalizedRGBBounds: NumericBounds?) async throws -> PreparedInput {
        try Task.checkCancellation()
        let scope = try model.renderer.encoder.beginBoundedPhotoWork(); defer { scope.finish() }
        let normalized = try await adapter.prepare(source, descriptor: descriptor, recipe: recipe, execution: execution,
            rawOverrides: rawOverrides, rawConfiguration: rawConfiguration, trustedNormalizedRGBBounds: trustedNormalizedRGBBounds)
        return try await normalizer.normalize(normalized, calibration: calibration, resources: resources, bounded: true)
    }
}

extension PreparedStyleModel {
    /// Prepare reusable calibration resources against the model ledger before frame admission.
    public func prepareRealtimeInput(working: WorkingImageContract, calibration: InputCalibration? = nil,
                                     resources: ModelResourceSet? = nil) throws -> RealtimeInputPreparer {
        try RealtimeInputPreparer(model: self, working: working, calibration: calibration, resources: resources ?? ModelResourceSet())
    }
}
