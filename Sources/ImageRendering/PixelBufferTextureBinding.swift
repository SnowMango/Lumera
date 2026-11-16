import Foundation
import Metal
import CoreVideo
import ImagingCore

/// Owns both the CVMetalTexture wrapper and its source storage through GPU use.
final class PixelBufferTextureBinding {
    let pixelBuffer: CVPixelBuffer
    let mapped: CVMetalTexture
    let texture: MTLTexture
    init(_ buffer: CVPixelBuffer, cache: CVMetalTextureCache, writable: Bool) throws {
        let format: MTLPixelFormat
        switch CVPixelBufferGetPixelFormatType(buffer) {
        case kCVPixelFormatType_32BGRA: format = .bgra8Unorm
        case kCVPixelFormatType_64RGBAHalf: format = .rgba16Float
        case kCVPixelFormatType_128RGBAFloat: format = .rgba32Float
        default: throw LabError.unsupported("Explicit PixelBuffer processing requires BGRA8 or RGBA floating-point storage")
        }
        var mapped: CVMetalTexture?
        let usage: MTLTextureUsage = writable ? [.shaderRead, .shaderWrite] : [.shaderRead]
        let attributes = [kCVMetalTextureUsage as String: usage.rawValue] as CFDictionary
        let status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, buffer, attributes,
            format, CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &mapped)
        guard status == kCVReturnSuccess, let mapped, let texture = CVMetalTextureGetTexture(mapped) else {
            throw LabError.io("Cannot map supplied PixelBuffer (\(status))")
        }
        pixelBuffer = buffer; self.mapped = mapped; self.texture = texture
    }
}
