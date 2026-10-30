import XCTest
import Foundation
import Metal
import Darwin
import ImagingCore
import ImageRendering

final class DeviceCorrectionPerformanceTests:XCTestCase {
    func testPreparedRuntimePerformanceAndCacheBounds() throws {
        guard ProcessInfo.processInfo.environment["LUMERA_CORRECTION_PERF"]=="1" else {throw XCTSkip("Opt-in release GPU benchmark")}
        #if DEBUG
        XCTFail("Performance acceptance requires a release build");return
        #endif
        let device=try XCTUnwrap(MTLCreateSystemDefaultDevice()),queue=try XCTUnwrap(device.makeCommandQueue())
        let renderer=try TextureEffectEncoder(device:device)
        var rows=[[String:Any]]()
        let film=try StylePresets.make("film-demo")
        var matrix=DeviceCorrection();matrix.whiteBalance.destination=Chromaticity(x:0.3457,y:0.3585);matrix.matrix.values=[0.95,0.02,0,0.01,0.97,0.01,0,0.02,0.96]
        var lines=["LUT_3D_SIZE 17"]
        for b in 0...16 {for g in 0...16 {for r in 0...16 {lines.append([r,g,b].map{String(pow(Double($0)/16,1.1))}.joined(separator:" "))}}}
        let asset=LUTAsset(name:"performance-only",cubeText:lines.joined(separator:"\n"))
        let scenarios:[(String,DeviceCorrection?,Profile,LUTAsset?)]=[("nil",nil,film,nil),("identity",DeviceCorrection(),film,nil),("matrix-wb",matrix,.standard,nil),("lut",nil,.standard,asset),("correction-and-film",matrix,film,asset)]
        func percentile(_ values:[Double],_ p:Double)->Double {let sorted=values.sorted();return sorted[min(sorted.count-1,Int(Double(sorted.count-1)*p))]}
        func rss()->UInt64 {
            var info=mach_task_basic_info(),count=mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size/MemoryLayout<integer_t>.size)
            let status=withUnsafeMutablePointer(to:&info){ptr in ptr.withMemoryRebound(to:integer_t.self,capacity:Int(count)){task_info(mach_task_self_,task_flavor_t(MACH_TASK_BASIC_INFO),$0,&count)}}
            return status==KERN_SUCCESS ? info.resident_size:0
        }
        for (width,height) in [(1280,960),(4032,3024)] {
            let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:width,height:height,mipmapped:false);descriptor.storageMode = .shared;descriptor.usage = .shaderRead
            let source=try XCTUnwrap(device.makeTexture(descriptor:descriptor))
            var pixels=[UInt8](repeating:128,count:width*height*4)
            for i in stride(from:3,to:pixels.count,by:4){pixels[i]=255}
            pixels.withUnsafeBytes{source.replace(region:MTLRegionMake2D(0,0,width,height),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:width*4)}
            let request=RenderRequest(input:InputDescriptor(width:width,height:height))
            for (name,correction,profile,asset) in scenarios {
                renderer.releaseCaches()
                let start=ProcessInfo.processInfo.systemUptime
                let style=try renderer.prepare(ResolvedStyle(profile:profile)),prepared=try renderer.prepareCorrection(correction,lut:asset)
                let preparationMS=(ProcessInfo.processInfo.systemUptime-start)*1000
                if name=="nil" || name=="identity" {XCTAssertNil(prepared)}
                for round in 0..<3 {
                    var gpu=[Double](),cpu=[Double](),latency=[Double]()
                    for index in 0..<64 {
                        try autoreleasepool {
                            let cmd=try XCTUnwrap(queue.makeCommandBuffer()),done=DispatchSemaphore(value:0)
                            let started=ProcessInfo.processInfo.systemUptime
                            _=try renderer.encode(source,style:style,correction:prepared,request:request,commandBuffer:cmd)
                            let encoded=ProcessInfo.processInfo.systemUptime
                            cmd.addCompletedHandler{_ in done.signal()};cmd.commit();done.wait()
                            XCTAssertNil(cmd.error)
                            if index>=4 {cpu.append((encoded-started)*1000);gpu.append((cmd.gpuEndTime-cmd.gpuStartTime)*1000);latency.append((ProcessInfo.processInfo.systemUptime-started)*1000)}
                        }
                    }
                    rows.append(["scenario":name,"width":width,"height":height,"round":round+1,"samples":60,"warmup":4,"correctionPasses":(prepared?.colorIsActive == true ? 1:0)+(prepared?.lutTexture != nil ? 1:0),"preparationMS":preparationMS,"cpuMedianMS":percentile(cpu,0.5),"gpuMedianMS":percentile(gpu,0.5),"gpuP95MS":percentile(gpu,0.95),"completionP95MS":percentile(latency,0.95),"cachedTextureBytes":renderer.cachedTextureBytes,"residentBytes":rss(),"metalAllocatedBytes":device.currentAllocatedSize])
                    print("Correction performance \(name) \(width)x\(height) round \(round+1): GPU median \(percentile(gpu,0.5)) ms, P95 \(percentile(gpu,0.95)) ms")
                    XCTAssertLessThanOrEqual(renderer.cachedTextureBytes,256*1024*1024)
                }
            }
            for index in 0..<30 {
                try autoreleasepool {
                    var correction=matrix;correction.matrix.values[0]=0.8+Double(index)*0.005
                    let prepared=try renderer.prepareCorrection(correction),style=try renderer.prepare(ResolvedStyle(profile:.standard))
                    let cmd=try XCTUnwrap(queue.makeCommandBuffer()),done=DispatchSemaphore(value:0)
                    _=try renderer.encode(source,style:style,correction:prepared,request:request,commandBuffer:cmd)
                    cmd.addCompletedHandler{_ in done.signal()};cmd.commit();done.wait();XCTAssertNil(cmd.error)
                    XCTAssertLessThanOrEqual(renderer.cachedTextureBytes,256*1024*1024)
                }
            }
            renderer.releaseCaches();XCTAssertEqual(renderer.cachedTextureBytes,0)
        }
        if let path=ProcessInfo.processInfo.environment["LUMERA_CORRECTION_PERF_OUTPUT"] {
            let report:[String:Any]=["device":device.name,"precision":"float16 (automatic promotion)","os":ProcessInfo.processInfo.operatingSystemVersionString,"rows":rows,"cacheAfterRelease":renderer.cachedTextureBytes,"residentAfterRelease":rss(),"notes":"CPU encoding and GPU command timestamps measured separately. No pixel readback. Style/LUT preparation outside loop. Desktop evidence does not establish iPhone frame rate."]
            try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:path))
        }
    }
}
