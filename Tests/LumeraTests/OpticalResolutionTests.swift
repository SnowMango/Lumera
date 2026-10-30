import XCTest
import Metal
import ImagingCore
@testable import ImageRendering
@testable import ImageAnalysis

final class OpticalResolutionTests:XCTestCase {
    func testPublicChoicesAndInternalContinuousGeometry()throws {
        XCTAssertEqual(EffectResolution.allCases.map(\.scale),[1,0.5,0.25,0.125,0.0625])
        let g=try OpticalProcessingGeometry(width:257,height:193,scale:0.3)
        XCTAssertEqual(g.width,78);XCTAssertEqual(g.height,58)
        XCTAssertEqual(g.scaleX,78.0/257);XCTAssertEqual(g.scaleY,58.0/193)
        for scale in [0.0,-1,1.1,Double.nan,.infinity] {XCTAssertThrowsError(try OpticalProcessingGeometry(width:2,height:2,scale:scale))}
        let request=RenderRequest(input:.init(width:2,height:2))
        XCTAssertEqual(request.glowScale,.full);XCTAssertEqual(request.halationScale,.full);XCTAssertEqual(request.softeningScale,.full)
        XCTAssertFalse(String(decoding:try JSON.encode(Profile.standard),as:UTF8.self).contains("glowScale"))
    }
    func testReductionKeepsSingleBrightPixelEnergy()throws {
        let device=try XCTUnwrap(MTLCreateSystemDefaultDevice()),queue=try XCTUnwrap(device.makeCommandQueue())
        let library=try RenderingResources.makeLibrary(device:device)
        let pipeline=try device.makeComputePipelineState(function:XCTUnwrap(library.makeFunction(name:"opticalReduce")))
        func texture(_ n:Int)throws->MTLTexture {
            let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba32Float,width:n,height:n,mipmapped:false)
            d.storageMode = .shared;d.usage=[.shaderRead,.shaderWrite];return try XCTUnwrap(device.makeTexture(descriptor:d))
        }
        let source=try texture(16),output=try texture(1)
        var pixels=[Float](repeating:0,count:16*16*4);pixels[0]=1;pixels[1]=1;pixels[2]=1
        pixels.withUnsafeBytes{source.replace(region:MTLRegionMake2D(0,0,16,16),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:16*16)}
        let command=try XCTUnwrap(queue.makeCommandBuffer()),encoder=try XCTUnwrap(command.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline);encoder.setTexture(source,index:0);encoder.setTexture(output,index:1)
        let parameters:[Float]=[1,0.7,0.15]
        parameters.withUnsafeBytes{encoder.setBytes($0.baseAddress!,length:$0.count,index:0)}
        encoder.dispatchThreads(.init(width:1,height:1,depth:1),threadsPerThreadgroup:.init(width:1,height:1,depth:1));encoder.endEncoding()
        command.commit();command.waitUntilCompleted();XCTAssertNil(command.error)
        var result=[Float](repeating:0,count:4)
        result.withUnsafeMutableBytes{output.getBytes($0.baseAddress!,bytesPerRow:16,from:MTLRegionMake2D(0,0,1,1),mipmapLevel:0)}
        XCTAssertEqual(result[0],1.0/256,accuracy:0.000001)
    }
    func testPreviewGPUCostAndApproximationReport()throws {
        let device=try XCTUnwrap(MTLCreateSystemDefaultDevice()),queue=try XCTUnwrap(device.makeCommandQueue())
        let encoder=try TextureEffectEncoder(device:device,precision:.float32),w=960,h=720
        let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba32Float,width:w,height:h,mipmapped:false)
        d.storageMode = .shared;d.usage=[.shaderRead,.shaderWrite]
        let input=try XCTUnwrap(device.makeTexture(descriptor:d))
        var pixels=[Float](repeating:0.1,count:w*h*4)
        for y in 0..<h {for x in 0..<w {
            let value:Float=(x>w/3 && x<w/2 && y>h/3 && y<h/2) || ((x-w*3/4)*(x-w*3/4)+(y-h/2)*(y-h/2)<36) ? 1:0.1
            let i=(y*w+x)*4;pixels[i]=value;pixels[i+1]=value;pixels[i+2]=value;pixels[i+3]=1
        }}
        pixels.withUnsafeBytes{input.replace(region:MTLRegionMake2D(0,0,w,h),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:w*16)}
        for effect in ["glow","halation","softening"] {
            var p=profile();p.parameters.glow.enabled=effect=="glow";p.parameters.halation.enabled=effect=="halation";p.parameters.softening.enabled=effect=="softening"
            let style=try encoder.prepare(ResolvedStyle(profile:p));var reference=[Float]()
            for scale in [EffectResolution.full,.quarter,.eighth,.sixteenth] {
                var request=RenderRequest(input:.init(width:w,height:h))
                request.glowScale=scale;request.halationScale=scale;request.softeningScale=scale
                var times=[Double](),values=[Float](repeating:0,count:pixels.count)
                for iteration in 0..<7 {
                    let command=try XCTUnwrap(queue.makeCommandBuffer())
                    let output=try encoder.encode(input,style:style,request:request,commandBuffer:command)
                    command.commit();command.waitUntilCompleted();XCTAssertNil(command.error)
                    if iteration>1 {times.append((command.gpuEndTime-command.gpuStartTime)*1000)}
                    if iteration==6 {values.withUnsafeMutableBytes{output.getBytes($0.baseAddress!,bytesPerRow:w*16,from:MTLRegionMake2D(0,0,w,h),mipmapLevel:0)}}
                }
                if scale == .full{reference=values}
                var sum=0.0,maximum:Float=0
                for i in values.indices where i%4 != 3 {let diff=values[i]-reference[i];sum+=Double(diff*diff);maximum=max(maximum,abs(diff))}
                XCTAssertTrue(values.allSatisfy{$0.isFinite})
                print("OpticalPreviewBenchmark device=\(device.name) size=\(w)x\(h) effect=\(effect) divisor=\(scale.rawValue) gpuMedianMS=\(times.sorted()[times.count/2]) rgbRMSE=\(sqrt(sum/Double(w*h*3))) maxRGBError=\(maximum)")
            }
        }
    }
    private func profile()->Profile {
        var p=Profile.standard
        p.parameters.softening.enabled=true;p.parameters.softening.amount=0.3;p.parameters.softening.sigma=8
        p.parameters.glow.enabled=true;p.parameters.glow.amount=0.4;p.parameters.glow.nearSigma=32;p.parameters.glow.farSigma=64
        p.parameters.halation.enabled=true;p.parameters.halation.amount=0.3;p.parameters.halation.sigma=12
        return p
    }
    func testIndependentSettingsAndCacheMatchRuntimeOnOddSizes()throws {
        let frame=try Fixtures.make(.point,width:257,height:193),renderer=try MetalRenderer()
        let device=try XCTUnwrap(MTLCreateSystemDefaultDevice()),queue=try XCTUnwrap(device.makeCommandQueue())
        let encoder=try TextureEffectEncoder(device:device,precision:.float32)
        let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba32Float,width:frame.width,height:frame.height,mipmapped:false)
        d.storageMode = .shared;d.usage=[.shaderRead,.shaderWrite]
        let texture=try XCTUnwrap(device.makeTexture(descriptor:d))
        frame.pixels.withUnsafeBytes{texture.replace(region:MTLRegionMake2D(0,0,frame.width,frame.height),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:frame.width*16)}
        let p=profile(),style=try ResolvedStyle(profile:p),prepared=try encoder.prepare(style)
        var request=RenderRequest(input:frame.descriptor)
        for setting in 0..<7 {
            request.glowScale=(setting==1 || setting==5) ? .sixteenth:.full
            request.halationScale=(setting==2 || setting==5) ? .eighth:.full
            request.softeningScale=(setting==3 || setting==5) ? .quarter:.full
            let expected=try renderer.render(frame,style:style,request:request).image
            let fresh=try MetalRenderer().render(frame,style:style,request:request).image
            XCTAssertEqual(expected.pixels,fresh.pixels,"Stale cached optical resolution")
            let command=try XCTUnwrap(queue.makeCommandBuffer())
            let output=try encoder.encode(texture,style:prepared,request:request,commandBuffer:command)
            command.commit();command.waitUntilCompleted();XCTAssertNil(command.error)
            var values=[Float](repeating:0,count:frame.pixels.count)
            values.withUnsafeMutableBytes{output.getBytes($0.baseAddress!,bytesPerRow:frame.width*16,from:MTLRegionMake2D(0,0,frame.width,frame.height),mipmapLevel:0)}
            XCTAssertEqual(output.width,frame.width);XCTAssertEqual(output.height,frame.height)
            XCTAssertLessThan(zip(values,expected.pixels).map{abs($0-$1)}.max()!,0.0001)
        }
    }
    func testFlatFieldPreservedAtEveryScaleAndTinyDimensions()throws {
        let renderer=try MetalRenderer(),style=try ResolvedStyle(profile:profile())
        for (w,h) in [(257,193),(1,7)] {
            let frame=try ImageFrame.solid(width:w,height:h,value:0.95)
            for scale in EffectResolution.allCases {
                var request=RenderRequest(input:frame.descriptor)
                request.glowScale=scale;request.halationScale=scale;request.softeningScale=scale
                let result=try renderer.render(frame,style:style,request:request).image
                XCTAssertTrue(result.pixels.allSatisfy{$0.isFinite})
                for i in stride(from:0,to:result.pixels.count,by:4){XCTAssertEqual(result.pixels[i],0.95,accuracy:0.0001)}
            }
        }
    }
}
