import Foundation
import Metal
import CoreVideo
import IOSurface

/// Identifies an allocation, not a texture view. Only memory retained by the engine
/// is charged here; the host remains responsible for its external buffer pool.
enum ProcessingStorageIdentity: Hashable {
    case object(ObjectIdentifier)
    case surface(UInt32)
    static func texture(_ value: MTLTexture) -> Self {
        var root = value
        while let parent = root.parent { root = parent }
        if let surface = root.iosurface { return .surface(IOSurfaceGetID(surface)) }
        if let buffer = root.buffer { return .object(ObjectIdentifier(buffer)) }
        return .object(ObjectIdentifier(root))
    }
    static func buffer(_ value: CVPixelBuffer) -> Self {
        if let surface = CVPixelBufferGetIOSurface(value)?.takeUnretainedValue() { return .surface(IOSurfaceGetID(surface)) }
        return .object(ObjectIdentifier(value))
    }
}

final class WeakProcessingCharge {
    weak var value: ProcessingResourceCharge?
    init(_ value: ProcessingResourceCharge) { self.value = value }
}

extension ProcessingResourceLedger {
    func borrow(_ texture: MTLTexture, adaptingPolicy: Bool = false) throws -> ProcessingResourceCharge {
        var root = texture
        while let parent = root.parent { root = parent }
        let bytes: Int
        if let surface = root.iosurface { bytes = IOSurfaceGetAllocSize(surface) }
        else if let buffer = root.buffer { bytes = buffer.allocatedSize }
        else { bytes = root.allocatedSize }
        return try borrow(identity: .texture(root), bytes: bytes, adaptingPolicy: adaptingPolicy)
    }
    func borrow(_ buffer: CVPixelBuffer) throws -> ProcessingResourceCharge {
        let bytes = CVPixelBufferGetIOSurface(buffer).map { IOSurfaceGetAllocSize($0.takeUnretainedValue()) } ?? CVPixelBufferGetDataSize(buffer)
        return try borrow(identity: .buffer(buffer), bytes: bytes)
    }
}
