import Foundation
import ImagingCore

/// Opt-in automatic preparation for a model session. Descriptor/topology changes prepare
/// resources explicitly here; stable frames only acquire existing storage.
public final class ModelProcessingResources: @unchecked Sendable {
    public let resources: ProcessingResources
    public init(resources: ProcessingResources) { self.resources = resources }
    package func submit(_ input: PreparedInput, plan: FrameRenderPlan, observations: ObservationRequirements?,
                        beforeCommit: () throws -> Void) throws -> ModelFrameSubmission {
        let renderer = plan.model.renderer
        try plan.model.registerProcessingResources(resources)
        if try !renderer.encoder.workRequirements(for: plan).requiresPixelProcessing {
            return try renderer.submit(input, plan: plan, observations: observations, beforeCommit: beforeCommit)
        }
        let request = try PreparedProcessingRequest(plan: plan)
        switch resources.prepare(request) {
        case .ready: break
        case .wouldBlock(let issue): throw issue
        case .failure(let error): throw error
        }
        let frame: FrameResources
        switch resources.acquireFrame(for: request) {
        case .ready(let acquired): frame = acquired
        case .unavailable(let issue): throw issue
        }
        return try renderer.submit(input, plan: plan, output: frame.outputTexture, workspace: frame.workspace,
                                   request: request, observations: observations, beforeCommit: beforeCommit)
    }
}
