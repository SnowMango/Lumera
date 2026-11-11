import Foundation
import ImagingCore
import ImageRendering

/// A photo decision with source replay information and no prepared input storage.
public final class PhotoSessionSnapshot: Sendable {
    public let source: PhotoSource
    public let inputFacts: FrameInputFacts
    public let observations: FrameObservations
    public let automatic: AutomaticControls
    public let modelID: String
    public let stamp: FrameStamp
    public let seed: UInt32
    public let inputWidth: Int
    public let inputHeight: Int
    public var canRedevelopRAW: Bool { source.canRedevelopRAW }

    let owner: UUID
    let model: PreparedStyleModel
    let variants: PhotoExecutionVariants

    init(source: PhotoSource, inputFacts: FrameInputFacts, inputWidth: Int, inputHeight: Int,
         observations: FrameObservations, automatic: AutomaticControls, owner: UUID, model: PreparedStyleModel, seed: UInt32) {
        self.source = source
        self.inputFacts = inputFacts
        self.inputWidth = inputWidth
        self.inputHeight = inputHeight
        self.observations = observations
        self.automatic = automatic
        self.owner = owner
        self.model = model
        modelID = model.compiled.identity
        stamp = inputFacts.stamp
        self.seed = seed
        variants = PhotoExecutionVariants(model: model, renderer: model.renderer)
    }

    func matches(_ input: PreparedInput) throws -> Bool {
        guard input.sourceID == inputFacts.sourceID, input.calibrationID == inputFacts.calibrationID,
              input.width == inputWidth, input.height == inputHeight else { return false }
        return try input.source.effectiveRecipe.digest() == inputFacts.effectiveRecipeDigest
    }
}

/// An independently owned output, the replayable photo decision, and the applied controls.
public struct PhotoSessionResult: Sendable {
    public let frame: RenderedFrame
    public let snapshot: PhotoSessionSnapshot
    public let decision: FrameDecision
}
