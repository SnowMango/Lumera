import Foundation
import CoreImage
import ImagingCore
import ImageRendering

/// A lightweight source descriptor for the ordered camera worker. Do not prepare input textures
/// or start tasks while building descriptors. The caller owns backing storage while waiting.
public struct FrameSource: Sendable {
    private var callbackPreparation: (@Sendable (ExecutionProfile, @escaping (Result<PreparedInput, Error>) -> Void) -> Void)? = nil
    let knownResidentBytes: Int
    let model: PreparedStyleModel?
    let prepare: @Sendable (ExecutionProfile) async throws -> PreparedInput

    /// Callback source for explicitly prepared resources. The provider must call completion
    /// exactly once after its GPU work ends, retaining borrowed backing through completion.
    public init(knownResidentBytes: Int,
                prepareWithCompletion: @escaping @Sendable (ExecutionProfile, @escaping (Result<PreparedInput, Error>) -> Void) -> Void) {
        self.knownResidentBytes = knownResidentBytes; model = nil
        callbackPreparation = prepareWithCompletion
        prepare = { execution in
            try await withCheckedThrowingContinuation { continuation in
                prepareWithCompletion(execution) { continuation.resume(with: $0) }
            }
        }
    }
    func beginPreparation(_ execution: ExecutionProfile, cancellation: SessionCancellation,
                          on queue: DispatchQueue, completion: @escaping (Result<PreparedInput, Error>) -> Void) {
        if let callbackPreparation {
            callbackPreparation(execution) { result in queue.async { completion(result) } }
        } else {
            // Compatibility adapter only for explicitly async/RAW source providers.
            let task = Task { try cancellation.check(); return try await prepare(execution) }
            cancellation.trackPreparation(task)
            Task {
                let result = await task.result
                cancellation.clearPreparation()
                queue.async { completion(result) }
            }
        }
    }

    /// A declared-range source using caller-supplied CIContext and explicitly prepared storage.
    /// Pending pixels stay internal to the session until the owning GPU command completes.
    public init(_ source: SourceImage, using prepared: PreparedRealtimeInput, context: CIContext) {
        self.init(knownResidentBytes: source.knownResidentBytes, prepareWithCompletion: { _, completion in
            completion(Result { try prepared.makeInput(source, context: context) })
        })
    }

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
    /// Supply inputResources to reuse measured Half conversion textures. Each conversion
    /// stage acquires only its own texture; the caller controls the pool's idle/resident limits.
    public init(_ source: SourceImage, using preparer: RealtimeInputPreparer, descriptor: SourceDescriptor,
                recipe: InputRecipe, additionalResidentBytes: Int = 0, rawOverrides: [RAWOverride] = [],
                rawConfiguration: RAWDevelopmentConfiguration? = nil, trustedNormalizedRGBBounds: NumericBounds? = nil,
                inputResources: ProcessingResources? = nil) {
        let (bytes, overflow) = source.knownResidentBytes.addingReportingOverflow(additionalResidentBytes)
        knownResidentBytes = overflow || additionalResidentBytes < 0 ? -1 : bytes
        model = preparer.model
        prepare = { execution in
            try await preparer.prepare(source, descriptor: descriptor, recipe: recipe, execution: execution,
                rawOverrides: rawOverrides, rawConfiguration: rawConfiguration, trustedNormalizedRGBBounds: trustedNormalizedRGBBounds, inputResources: inputResources)
        }
    }
}
