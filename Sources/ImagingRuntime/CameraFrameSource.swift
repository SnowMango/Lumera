import ImagingCore
import ImageRendering

/// A lightweight source descriptor for the ordered camera worker. Do not prepare input textures
/// or start tasks while building descriptors. The caller owns backing storage while waiting.
public struct CameraFrameSource: Sendable {
    let knownResidentBytes: Int
    let model: PreparedCameraModel?
    let prepare: @Sendable (ExecutionProfile) async throws -> PreparedInput

    /// A custom provider receives the frame allowance after declared backing is deducted.
    /// Declare all retained backing outside the returned input and honor the allowance for peak
    /// provider-owned allocations, including temporaries. The SDK checks the returned input's
    /// size but cannot measure hidden allocations. Return immutable pixels and await all
    /// submitted work before returning or throwing, even when the task is cancelled.
    public init(knownResidentBytes: Int, prepare: @escaping @Sendable (ExecutionProfile) async throws -> PreparedInput) {
        self.knownResidentBytes = knownResidentBytes
        self.prepare = prepare
        model = nil
    }

    /// Borrow the source until enqueue returns. This accounts for pixel-buffer/Data bytes and
    /// SDK textures, calibration and reductions. Declare extra known backing (for example a
    /// bitmap-backed CIImage) separately. Opaque Core Image and RAW decoder memory is external.
    /// If supplied, the trusted bound must cover finite RGB after normalization into encoded
    /// sRGB, not the camera's raw channel or code-value range. Do not supply it for RAW.
    public init(_ source: SourceImage, using preparer: RealtimeInputPreparer, descriptor: SourceDescriptor,
                recipe: InputRecipe, additionalResidentBytes: Int = 0, rawOverrides: [RAWOverride] = [],
                rawConfiguration: RAWDevelopmentConfiguration? = nil, trustedNormalizedRGBBounds: NumericBounds? = nil) {
        let (bytes, overflow) = source.knownResidentBytes.addingReportingOverflow(additionalResidentBytes)
        knownResidentBytes = overflow || additionalResidentBytes < 0 ? -1 : bytes
        model = preparer.model
        prepare = { execution in
            try await preparer.prepare(source, descriptor: descriptor, recipe: recipe, execution: execution,
                rawOverrides: rawOverrides, rawConfiguration: rawConfiguration, trustedNormalizedRGBBounds: trustedNormalizedRGBBounds)
        }
    }
}
