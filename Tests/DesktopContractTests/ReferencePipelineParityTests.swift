import XCTest
import Metal
import ImagingCore
import ImageRendering
import ImageAnalysis

final class ReferencePipelineParityTests: XCTestCase {
    func testNeutralReferenceReturnsNoGlowLayer() throws {
        let image = try ImageFrame.solid(width: 1, height: 1, value: 0.4)
        let result = try MetalRenderer().render(image, style: ResolvedStyle(profile: .standard), request: .init(input: image.descriptor))
        XCTAssertNil(result.glowLayer)
        XCTAssertEqual(result.image.pixels, image.pixels)
    }
    func testFloat32PathsAgreeWithOwnedOutput() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let encoder = try TextureEffectEncoder(device: device, precision: .float32)
        let reference = try MetalRenderer()
        for size in [(257,193),(1,1)] {
            let image = try Fixtures.make(.texture, width: size.0, height: size.1)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: size.0, height: size.1, mipmapped: false)
            descriptor.storageMode = .shared; descriptor.usage = [.shaderRead,.shaderWrite]
            let source = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
            image.pixels.withUnsafeBytes { source.replace(region: MTLRegionMake2D(0,0,size.0,size.1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: size.0*16) }
            for name in ["standard", "digital-demo", "film-demo"] {
                let profile = try StylePresets.make(name), style = try ResolvedStyle(profile: profile)
                let prepared = try encoder.prepare(style)
                for index in 0..<3 {
                    var request = RenderRequest(input: image.descriptor, maximumLongEdge: index == 2 ? 97 : nil)
                    request.frameIndex = UInt32(index); request.previewGlow = index != 1
                    request.glowScale = .eighth; request.halationScale = .quarter; request.softeningScale = .half
                    let expected = try reference.render(image, style: style, request: request).image
                    let command = try XCTUnwrap(queue.makeCommandBuffer())
                    let output = try encoder.encode(source, style: prepared, request: request, commandBuffer: command)
                    let ownedDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: output.pixelFormat, width: output.width, height: output.height, mipmapped: false)
                    ownedDescriptor.storageMode = .shared
                    let owned = try XCTUnwrap(device.makeTexture(descriptor: ownedDescriptor))
                    let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
                    blit.copy(from: output, to: owned); blit.endEncoding()
                    command.commit(); command.waitUntilCompleted(); XCTAssertNil(command.error)
                    var actual = [Float](repeating: 0, count: expected.pixels.count)
                    actual.withUnsafeMutableBytes { owned.getBytes($0.baseAddress!, bytesPerRow: owned.width*16, from: MTLRegionMake2D(0,0,owned.width,owned.height), mipmapLevel: 0) }
                    XCTAssertLessThanOrEqual(zip(actual,expected.pixels).map { abs($0-$1) }.max()!, 0.0001, "\(name)/\(index)")
                }
            }
        }
    }
}
