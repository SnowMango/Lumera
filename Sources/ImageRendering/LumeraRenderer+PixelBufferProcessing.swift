import Foundation
import CoreVideo
import CoreImage
import Metal
import ImagingCore

extension LumeraRenderer {
    /// Writes the supplied output buffer through the supplied texture cache.
    /// Inputs must satisfy request.input's opaque encoded-sRGB contract. No CI adapter,
    /// output PixelBuffer allocation or cache creation occurs here.
    @discardableResult
    public func processBuffer(_ input: CVPixelBuffer, output: CVPixelBuffer, textureCache: CVMetalTextureCache,
                              workspace: ProcessingWorkspace, request: PreparedProcessingRequest,
                              completion: @escaping (Result<CVPixelBuffer, Error>) -> Void) -> FrameSubmission {
        processPrepared(output: output, workspace: workspace, request: request,
            retaining: [input, output, textureCache],
            borrow: { try [workspace.storage.ledger.borrow(input), workspace.storage.ledger.borrow(output)] }, completion: completion) { command in
                guard input !== output else { throw LabError.invalid("PixelBuffer input and output must not alias") }
                // This entry accepts already standardized RGB. Tagged wide-color sources
                // require an explicit adapter; silently treating them as sRGB changes pixels.
                if let space = CVImageBufferGetColorSpace(input)?.takeUnretainedValue() {
                    guard space == Self.sRGB || space == Self.extendedSRGB else {
                        throw LabError.unsupported("PixelBuffer requires an explicit sRGB color conversion")
                    }
                }
                let propagated = CVBufferCopyAttachments(input, .shouldPropagate) as? [String: Any] ?? [:]
                let other = CVBufferCopyAttachments(input, .shouldNotPropagate) as? [String: Any] ?? [:]
                let attachments = other.merging(propagated) { _, new in new }
                try self.validateBuffer(input, attachments: attachments)
                guard LumeraImageMetadata.orientation(attachments) == .up else {
                    throw LabError.unsupported("Direct RGB input must already be orientation-normalized")
                }
                let source = try PixelBufferTextureBinding(input, cache: textureCache, writable: false)
                let target = try PixelBufferTextureBinding(output, cache: textureCache, writable: true)
                _ = ProcessingCommandOwner.attach(to: command, retaining: [source, target])
                try self.validateProcessing(input: source.texture, output: target.texture, request: request, command: command)
                try self.encoder.encodePrepared(source.texture, output: target.texture, prepared: request,
                                                arena: workspace.storage.arena, command: command)
                CVBufferRemoveAllAttachments(output)
                let properties = LumeraImageMetadata.output(propagated, width: request.outputWidth,
                    height: request.outputHeight, depth: target.texture.pixelFormat == .rgba32Float ? 32 : (target.texture.pixelFormat == .rgba16Float ? 16 : 8),
                    dynamicRange: request.options.dynamicRange)
                LumeraImageMetadata.attach(properties, to: output, dynamicRange: request.options.dynamicRange)
            }
    }
}
