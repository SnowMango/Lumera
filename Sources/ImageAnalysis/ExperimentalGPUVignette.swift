import ImageRendering
import Foundation
import Metal
import ImagingCore

/// Development-only neutral pipeline: transfer → vignette → finish → GPU radial reduction.
/// No full image readback. Geometry is prepared once in Double to fix bin membership at boundaries.
/// This experiment is NOT used by CalibrationService or the normal renderer.
public final class ExperimentalGPUVignette {
    private let device:MTLDevice,queue:MTLCommandQueue
    private let source:MTLTexture,linear:MTLTexture,attenuated:MTLTexture,encoded:MTLTexture
    private let bins:MTLBuffer,partials:MTLBuffer,output:MTLBuffer
    private let pipelines:[String:MTLComputePipelineState]
    private let width:Int,height:Int,segments:Int
    public var deviceName:String {device.name}
    public private(set) var evaluations=0
    public let readbackBytesPerEvaluation=32*MemoryLayout<SIMD2<Float>>.stride
    public init(source image:ImageFrame) throws {
        try image.validateStorage()
        guard image.width>=64,image.height>=64,image.pixels.allSatisfy({(0...1).contains($0)}) else {
            throw LabError.invalid("GPU 暗角实验仅支持至少 64 × 64 像素的 SDR 全幅输入")
        }
        try Task.checkCancellation()
        guard let device=MTLCreateSystemDefaultDevice(),let queue=device.makeCommandQueue() else{throw LabError.noMetal}
        self.device=device;self.queue=queue;width=image.width;height=image.height;segments=(image.width*image.height+255)/256
        // Preserve strict math for both rendering and experimental measurement kernels.
        let options=MTLCompileOptions();options.fastMathEnabled=false
        let library=try RenderingResources.makeLibrary(device:device,options:options,additionalSource:Self.statistics)
        var states=[String:MTLComputePipelineState]()
        for name in ["transfer","vignette","finish","experimentPartial","experimentReduce"] {
            guard let function=library.makeFunction(name:name) else{throw LabError.io("缺少 GPU 实验函数")}
            states[name]=try device.makeComputePipelineState(function:function)
        }
        pipelines=states
        func texture() throws -> MTLTexture {
            let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba32Float,width:image.width,height:image.height,mipmapped:false)
            d.storageMode = .shared;d.usage=[.shaderRead,.shaderWrite]
            guard let t=device.makeTexture(descriptor:d) else{throw LabError.io("GPU 实验纹理分配失败")};return t
        }
        source=try texture();linear=try texture();attenuated=try texture();encoded=try texture()
        let diagonal=hypot(Double(image.width),Double(image.height))/2
        var geometry=[UInt8]();geometry.reserveCapacity(image.width*image.height)
        for y in 0..<image.height {
            try Task.checkCancellation()
            for x in 0..<image.width {
                let radius=hypot(Double(x)+0.5-Double(image.width)/2,Double(y)+0.5-Double(image.height)/2)/diagonal
                geometry.append(UInt8(min(31,Int(radius*32))))
            }
        }
        guard let bins=geometry.withUnsafeBytes({device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared)}),
              let partials=device.makeBuffer(length:segments*32*8,options:.storageModeShared),
              let output=device.makeBuffer(length:32*8,options:.storageModeShared) else{throw LabError.io("GPU 实验统计缓冲区分配失败")}
        self.bins=bins;self.partials=partials;self.output=output
        image.pixels.withUnsafeBytes{source.replace(region:MTLRegionMake2D(0,0,width,height),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:width*16)}
        guard let command=queue.makeCommandBuffer() else{throw LabError.noMetal}
        try pass(command,"transfer",source,linear,[-1]);try complete(command)
    }
    private func pass(_ command:MTLCommandBuffer,_ name:String,_ input:MTLTexture,_ destination:MTLTexture,_ values:[Float]) throws {
        try Task.checkCancellation()
        guard let encoder=command.makeComputeCommandEncoder(),let pipeline=pipelines[name] else{throw LabError.noMetal}
        encoder.setComputePipelineState(pipeline);encoder.setTexture(input,index:0);encoder.setTexture(destination,index:1)
        if name=="finish" {encoder.setTexture(input,index:2);encoder.setTexture(input,index:3)}
        values.withUnsafeBytes{encoder.setBytes($0.baseAddress!,length:$0.count,index:0)}
        encoder.dispatchThreads(MTLSize(width:width,height:height,depth:1),threadsPerThreadgroup:MTLSize(width:16,height:16,depth:1));encoder.endEncoding()
    }
    private func complete(_ command:MTLCommandBuffer) throws {
        try Task.checkCancellation();command.commit();command.waitUntilCompleted()
        if let error=command.error{throw error};try Task.checkCancellation()
    }
    public func radial(_ vignette:Vignette) throws -> [Double] {
        var p=StyleParameters();p.vignette=vignette;try p.validate();try Task.checkCancellation()
        guard let command=queue.makeCommandBuffer() else{throw LabError.noMetal}
        try pass(command,"vignette",linear,attenuated,[vignette.enabled ? Float(vignette.amountEV):0,Float(vignette.startRadius),Float(vignette.falloff),Float(vignette.centerX),Float(vignette.centerY)])
        try pass(command,"finish",attenuated,encoded,Array(repeating:0,count:8))
        for name in ["experimentPartial","experimentReduce"] {
            guard let encoder=command.makeComputeCommandEncoder(),let pipeline=pipelines[name] else{throw LabError.noMetal}
            encoder.setComputePipelineState(pipeline);encoder.setTexture(encoded,index:0)
            encoder.setBuffer(bins,offset:0,index:0);encoder.setBuffer(partials,offset:0,index:1);encoder.setBuffer(output,offset:0,index:2)
            var count=UInt32(segments);encoder.setBytes(&count,length:4,index:3)
            encoder.dispatchThreads(MTLSize(width:name=="experimentPartial" ? segments:32,height:1,depth:1),threadsPerThreadgroup:MTLSize(width:32,height:1,depth:1));encoder.endEncoding()
        }
        try complete(command);evaluations+=1
        let values=output.contents().bindMemory(to:SIMD2<Float>.self,capacity:32)
        var radial=[Double]()
        for i in 0..<32 {
            guard values[i].y>0,values[i].x.isFinite else{throw LabError.measurement("GPU 实验径向统计无效")}
            radial.append(Double(values[i].x)/Double(values[i].y))
        }
        let center=radial.prefix(3).reduce(0,+)/3
        guard center>1e-6 else{throw LabError.measurement("平场中心太暗，无法可靠比较暗角")}
        return radial.map{$0/center}
    }
    private static let statistics = """
    // Each segment has fixed membership and compensated sums; no unordered float atomics.
    kernel void experimentPartial(texture2d<float,access::read> src[[texture(0)]],
      const device uchar* bins[[buffer(0)]],device float2* partials[[buffer(1)]],
      constant uint& segments[[buffer(3)]],uint id[[thread_position_in_grid]]) {
      if(id>=segments)return;
      float sums[32]={0},corrections[32]={0};uint counts[32]={0};
      uint end=min((id+1)*256,src.get_width()*src.get_height());
      for(uint i=id*256;i<end;i++) {
        uint b=bins[i];float value=dot(decodeRGB(src.read(uint2(i%src.get_width(),i/src.get_width())).rgb),lumaWeights);
        float adjusted=value-corrections[b],next=sums[b]+adjusted;
        corrections[b]=(next-sums[b])-adjusted;sums[b]=next;counts[b]++;
      }
      for(uint b=0;b<32;b++)partials[id*32+b]=float2(sums[b],float(counts[b]));
    }
    kernel void experimentReduce(const device float2* partials[[buffer(1)]],device float2* output[[buffer(2)]],
      constant uint& segments[[buffer(3)]],uint bin[[thread_position_in_grid]]) {
      if(bin>=32)return;float sum=0,correction=0,count=0;
      for(uint i=0;i<segments;i++) {float2 p=partials[i*32+bin];float adjusted=p.x-correction,next=sum+adjusted;correction=(next-sum)-adjusted;sum=next;count+=p.y;}
      output[bin]=float2(sum,count);
    }
    """
}
