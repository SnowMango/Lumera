import Foundation
import CoreImage
import Metal
import ImagingCore

extension LumeraRenderer {
    /// Uses the supplied context and output storage. The image target is single-write.
    /// No content-range scan is performed: request.options declares the input contract.
    @discardableResult
    public func processImage(_ input: CIImage, output: CIImageOutput, context: CIContext,
                             workspace: ProcessingWorkspace, request: PreparedProcessingRequest,
                             completion: @escaping (Result<CIImage, Error>) -> Void) -> FrameSubmission {
        return processPrepared(output: output.image, workspace: workspace, request: request,
            retaining: [input, output, context], additionalClaim: { output.claim() },
            borrow: { try [workspace.storage.ledger.borrow(output.texture)] }, completion: completion) { command in
                let normalized = try self.normalizedSource(input, metadata: nil, orientation: nil,
                                                          dynamicRange: request.options.dynamicRange)
                guard normalized.bounds.width == CGFloat(request.input.width),
                      normalized.bounds.height == CGFloat(request.input.height),
                      output.colorSpace == Self.colorSpace(for: request.options.dynamicRange) else {
                    throw LabError.invalid("CI geometry or output color space differs from prepared request")
                }
                guard let source = workspace.storage.input?.texture else { throw FrameAdmissionIssue.incompatibleResources }
                try self.validateProcessing(input: source, output: output.texture, request: request, command: command)
                context.render(normalized.image, to: source, commandBuffer: command, bounds: normalized.bounds,
                               colorSpace: Self.colorSpace(for: request.options.dynamicRange))
                try self.encoder.encodePrepared(source, output: output.texture, prepared: request,
                                                arena: workspace.storage.arena, command: command)
            }
    }
    func processNormalizedImage<T>(_ image: CIImage, bounds: CGRect, output: MTLTexture, result: T,
                                   context: CIContext, workspace: ProcessingWorkspace,
                                   request: PreparedProcessingRequest, retaining: [AnyObject],
                                   completion: @escaping (Result<T, Error>) -> Void) -> FrameSubmission {
        processPrepared(output: result, workspace: workspace, request: request,
                        retaining: retaining + [image, output, context], completion: completion) { command in
            guard let input = workspace.storage.input?.texture else { throw FrameAdmissionIssue.incompatibleResources }
            try self.validateProcessing(input: input, output: output, request: request, command: command)
            context.render(image, to: input, commandBuffer: command, bounds: bounds,
                           colorSpace: Self.colorSpace(for: request.options.dynamicRange))
            try self.encoder.encodePrepared(input, output: output, prepared: request,
                                           arena: workspace.storage.arena, command: command)
        }
    }

}
