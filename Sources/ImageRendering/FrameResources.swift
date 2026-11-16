import Foundation
import Metal
import CoreImage
import ObjectiveC
import ImagingCore

private var processingOutputLeaseKey: UInt8 = 0

/// Owns base storage, never the escaping texture view to which this lease is attached.
private final class ProcessingOutputLease {
    let storage: ProcessingTextureStorage
    let recycle: (ProcessingTextureStorage) -> Void
    init(_ storage: ProcessingTextureStorage, recycle: @escaping (ProcessingTextureStorage) -> Void) {
        self.storage = storage; self.recycle = recycle
    }
    deinit { recycle(storage) }
}

public final class FrameResources: @unchecked Sendable {
    public let workspace: ProcessingWorkspace
    public let outputTexture: MTLTexture
    init(workspace: ProcessingWorkspace, output: ProcessingTextureStorage,
         recycle: @escaping (ProcessingTextureStorage) -> Void) throws {
        self.workspace = workspace
        guard let view = output.texture.makeTextureView(pixelFormat: output.texture.pixelFormat) else {
            throw LabError.io("Cannot create leased output texture view")
        }
        outputTexture = view
        objc_setAssociatedObject(view, &processingOutputLeaseKey,
                                 ProcessingOutputLease(output, recycle: recycle), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
    /// Explicit lightweight image creation; no new pixel allocation or render.
    public func makeImageOutput(colorSpace: CGColorSpace) throws -> CIImageOutput {
        try CIImageOutput(texture: outputTexture, colorSpace: colorSpace)
    }
}

/// Binds a single image result to an explicitly provided writable texture.
/// Retaining the image keeps its storage alive; do not reuse this target for a new frame.
public final class CIImageOutput: @unchecked Sendable {
    public let image: CIImage
    public let texture: MTLTexture
    public let colorSpace: CGColorSpace
    private let lock = UnfairLock()
    private var claimed = false
    public init(texture: MTLTexture, colorSpace: CGColorSpace, properties: [String: Any] = [:]) throws {
        var options: [CIImageOption: Any] = [.colorSpace: colorSpace]
        if #available(iOS 18, macOS 15, *), colorSpace == LumeraRenderer.extendedSRGB { options[.contentHeadroom] = 0 }
        guard let wrapped = CIImage(mtlTexture: texture, options: options) else {
            throw LabError.io("Cannot wrap output texture")
        }
        let image = properties.isEmpty ? wrapped : wrapped.settingProperties(properties)
        self.image = image; self.texture = texture; self.colorSpace = colorSpace
        // CI may retain a view/IOSurface instead of this exact Objective-C object.
        // Retain the output view explicitly, without a back-reference to the image.
        objc_setAssociatedObject(image, &processingOutputLeaseKey, texture, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
    func claim() -> Bool { lock.withLock { guard !claimed else { return false }; claimed = true; return true } }
}
