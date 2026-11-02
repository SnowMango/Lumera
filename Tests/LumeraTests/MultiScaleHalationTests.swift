import XCTest
import Metal
import ImagingCore
import ImageRendering
@testable import ImageAnalysis

final class MultiScaleHalationTests: XCTestCase {
    /// A narrow bright bar spanning the second dimension exercises the same
    /// clamped separable convolution and subpixel upsampling as a dense image.
    func testLinearRGBMatchesDoubleOracleAtEveryResolution() throws {
        let width = 2049, height = 3
        var frame = try ImageFrame.solid(width:width,height:height,value:0)
        let first = 1015, last = 1025
        for y in 0..<height { for x in first...last { for c in 0..<3 {
            frame.pixels[(y*width+x)*4+c]=1
        }}}
        let renderer = try MetalRenderer(),device=try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue=try XCTUnwrap(device.makeCommandQueue()),halfEncoder=try TextureEffectEncoder(device:device,precision:.float16)
        let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba32Float,width:width,height:height,mipmapped:false)
        descriptor.storageMode = .shared;descriptor.usage = [.shaderRead,.shaderWrite]
        let input=try XCTUnwrap(device.makeTexture(descriptor:descriptor))
        frame.pixels.withUnsafeBytes { input.replace(region:MTLRegionMake2D(0,0,width,height),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:width*16) }
        for radius in [0.1,0.25,0.5,1,4,32] {
            var profile = Profile.standard
            var h = profile.parameters.halation
            h.enabled=true;h.radius=radius;h.amount=1;h.red=0.9;h.green=0.55;h.blue=0.3
            profile.parameters.halation=h
            let style = try ResolvedStyle(profile:profile),kernel=try HalationReference.kernel(radius:radius)
            let prepared=try halfEncoder.prepare(style)
            for resolution in EffectResolution.allCases {
                var request=RenderRequest(input:frame.descriptor)
                request.halationScale=resolution
                let out=try renderer.render(frame,style:style,request:request).image
                let command=try XCTUnwrap(queue.makeCommandBuffer())
                let half=try halfEncoder.encode(input,style:prepared,request:request,commandBuffer:command)
                command.commit();command.waitUntilCompleted()
                XCTAssertNil(command.error)
                var halfPixels=[Float16](repeating:0,count:width*height*4)
                halfPixels.withUnsafeMutableBytes { half.getBytes($0.baseAddress!,bytesPerRow:width*8,from:MTLRegionMake2D(0,0,width,height),mipmapLevel:0) }
                let step=resolution.rawValue,n=(width+step-1)/step
                let ratio=Double(width)/Double(n)
                var reduced=[Double](repeating:0,count:n)
                for i in 0..<n {
                    let lower=max(Double(first),Double(i)*ratio)
                    let upper=min(Double(last+1),Double(i+1)*ratio)
                    reduced[i]=max(0,upper-lower)/ratio
                }
                var spread=[SIMD3<Double>](repeating:.zero,count:n)
                for level in kernel.sigmas.indices {
                    let weights=kernel.weights(component:level,pixelScale:Double(n)/2048)
                    let gains=SIMD3(kernel.mixtures[0][level],kernel.mixtures[1][level],kernel.mixtures[2][level])
                    for i in 0..<n {
                        var sum=0.0
                        for j in weights.indices {sum += weights[j]*reduced[min(n-1,max(0,i+j-weights.count/2))]}
                        spread[i] += gains*sum
                    }
                }
                var maxError=0.0,maxHalfError=0.0
                for x in 0..<width where !(first...last).contains(x) {
                    let coord=(Double(x)+0.5)/ratio-0.5,i=Int(floor(coord)),t=coord-floor(coord)
                    let value=spread[max(0,i)]*(1-t)+spread[min(n-1,i+1)]*t
                    for c in 0..<3 {
                        let expected=AcceptanceReference.encode(value[c]*[h.red,h.green,h.blue][c])
                        let actual=Double(out.pixels[(width+x)*4+c])
                        maxHalfError=max(maxHalfError,abs(Double(halfPixels[(width+x)*4+c])-expected))
                        maxError=max(maxError,abs(expected-actual))
                    }
                }
                XCTAssertLessThanOrEqual(maxHalfError,0.002,"half precision radius=\(radius), processing divisor=\(step)")
                XCTAssertLessThanOrEqual(maxError,0.0001,"radius=\(radius), processing divisor=\(step)")
            }
        }
    }
}
