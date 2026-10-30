import XCTest
import Metal
import ImagingCore
@testable import ImageRendering

final class ColorTransformTests:XCTestCase {
    func testLinearExposurePermutationAndSingularMatrix() throws {
        var c=ColorResponse()
        XCTAssertEqual(try ColorTransform.prepare(c).apply([0.18,0.4,0.9]),[0.18,0.4,0.9])
        c.exposureEV=1
        let a=try ColorTransform.prepare(c).apply([0.18,0.4,0.9])
        XCTAssertEqual(a[0],0.36,accuracy:1e-12);XCTAssertEqual(a[2],1.8,accuracy:1e-12)
        c.exposureEV=0;c.matrix.values=[0,1,0,0,0,1,1,0,0]
        XCTAssertEqual(try ColorTransform.prepare(c).apply([0.1,0.2,0.3]),[0.2,0.3,0.1])
        c.matrix.values=Array(repeating:[0.2126,0.7152,0.0722],count:3).flatMap{$0}
        let mono=try ColorTransform.prepare(c).apply([1,0,0])
        for x in mono {XCTAssertEqual(x,0.2126,accuracy:1e-12)}
    }
    func testBradfordWhiteMappingAndInverse() throws {
        var c=ColorResponse();c.whiteBalance.destination=Chromaticity(x:0.3457,y:0.3585)
        let forward=try ColorTransform.prepare(c)
        let white=forward.apply([1,1,1])
        // Independent known XYZ of D50, converted with standard sRGB XYZ inverse.
        let x=0.3457/0.3585,z=(1-0.3457-0.3585)/0.3585
        let expected=[3.2409699419*x-1.5373831776-0.4986107603*z,
                      -0.9692436363*x+1.8759675015+0.0415550574*z,
                      0.0556300797*x-0.2039769589+1.0569715142*z]
        for i in 0..<3 {XCTAssertEqual(white[i],expected[i],accuracy:1e-8)}
        c.whiteBalance=WhiteBalanceCorrection(source:c.whiteBalance.destination,destination:.d65)
        let reverse=try ColorTransform.prepare(c)
        let original=[-0.1,0.18,1.2],restored=reverse.apply(forward.apply(original))
        for i in 0..<3 {XCTAssertEqual(restored[i],original[i],accuracy:1e-10)}
    }
    func testRejectInvalidDerivedWhiteAndMatrix() throws {
        var c=ColorResponse();c.matrix.values=[];XCTAssertThrowsError(try ColorTransform.prepare(c))
        c=ColorResponse();c.matrix.values[0] = .infinity;XCTAssertThrowsError(try ColorTransform.prepare(c))
        c=ColorResponse();c.whiteBalance.source=Chromaticity(x:0.01,y:0.01)
        XCTAssertThrowsError(try ColorTransform.prepare(c),"Nonpositive cone responses cannot define adaptation")
        c=ColorResponse();c.whiteBalance.source=Chromaticity(x:0.3,y:Double.leastNonzeroMagnitude)
        XCTAssertThrowsError(try ColorTransform.prepare(c))
    }
    func testGPUColorUsesLinearExposureThenMatrixWithoutEarlyClipping() throws {
        guard let device=MTLCreateSystemDefaultDevice(),let queue=device.makeCommandQueue(),let cmd=queue.makeCommandBuffer() else {throw XCTSkip("Metal unavailable")}
        let library=try RenderingResources.makeLibrary(device:device)
        let pipeline=try device.makeComputePipelineState(function:XCTUnwrap(library.makeFunction(name:"colorResponse")))
        let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba32Float,width:1,height:1,mipmapped:false);d.storageMode = .shared;d.usage=[.shaderRead,.shaderWrite]
        let input=try XCTUnwrap(device.makeTexture(descriptor:d)),output=try XCTUnwrap(device.makeTexture(descriptor:d))
        let pixels:[Float]=[0.5,0.25,0.75,1]
        pixels.withUnsafeBytes{input.replace(region:MTLRegionMake2D(0,0,1,1),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:16)}
        var c=ColorResponse();c.exposureEV=1;c.matrix.values=[0,0,1,0,1,0,-1,0,0]
        let p=try ColorTransform.prepare(c).uniforms
        let encoder=try XCTUnwrap(cmd.makeComputeCommandEncoder());encoder.setComputePipelineState(pipeline)
        encoder.setTexture(input,index:0);encoder.setTexture(output,index:1)
        p.withUnsafeBytes{encoder.setBytes($0.baseAddress!,length:$0.count,index:0)}
        encoder.dispatchThreads(MTLSize(width:1,height:1,depth:1),threadsPerThreadgroup:MTLSize(width:1,height:1,depth:1));encoder.endEncoding();cmd.commit();cmd.waitUntilCompleted()
        XCTAssertEqual(cmd.status,.completed)
        var result=[Float](repeating:0,count:4);result.withUnsafeMutableBytes{output.getBytes($0.baseAddress!,bytesPerRow:16,from:MTLRegionMake2D(0,0,1,1),mipmapLevel:0)}
        func decode(_ v:Double)->Double {pow((v+0.055)/1.055,2.4)}
        func encode(_ v:Double)->Double {let sign=v<0 ? -1.0:1.0;return sign*(1.055*pow(abs(v),1/2.4)-0.055)}
        let expected=[encode(2*decode(0.75)),encode(2*decode(0.25)),encode(-2*decode(0.5))]
        for i in 0..<3 {XCTAssertEqual(Double(result[i]),expected[i],accuracy:0.00001)}
        XCTAssertGreaterThan(result[0],1);XCTAssertLessThan(result[2],0)
    }
}
