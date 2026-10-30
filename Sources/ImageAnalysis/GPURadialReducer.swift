import ImageRendering
import Foundation
import Metal
import ImagingCore

public struct RadialStatistics:Sendable {
    public let radial:[Double]
    public let mean:Double
}

/// Fixed-order, compensated reduction, as validated by the vignette experiment.
/// One geometry/buffer set is retained per renderer, bounded to the latest dimensions.
/// The additional encoded sum supplies the same mean metric as the CPU measurement.
final class GPURadialReducer {
    private let device:MTLDevice
    private let partialPipeline:MTLComputePipelineState,reducePipeline:MTLComputePipelineState
    private var width=0,height=0,segments=0
    private var bins:MTLBuffer?,partials:MTLBuffer?,output:MTLBuffer?
    var cachedBufferBytes:Int {[bins,partials,output].compactMap{$0}.reduce(0){$0+$1.length}}
    func releaseCaches() {bins=nil;partials=nil;output=nil;width=0;height=0;segments=0}
    init(device:MTLDevice) throws {
        self.device=device
        let options=MTLCompileOptions();options.fastMathEnabled=false
        let library=try device.makeLibrary(source:Self.shader,options:options)
        guard let partial=library.makeFunction(name:"radialPartial"),let reduce=library.makeFunction(name:"radialReduce") else {throw LabError.io("缺少 GPU 暗角测量函数")}
        partialPipeline=try device.makeComputePipelineState(function:partial)
        reducePipeline=try device.makeComputePipelineState(function:reduce)
    }
    private func prepare(width:Int,height:Int) throws {
        guard width != self.width || height != self.height else{return}
        let diagonal=hypot(Double(width),Double(height))/2
        var geometry=[UInt8]();geometry.reserveCapacity(width*height)
        for y in 0..<height {
            try Task.checkCancellation()
            for x in 0..<width {
                let radius=hypot(Double(x)+0.5-Double(width)/2,Double(y)+0.5-Double(height)/2)/diagonal
                geometry.append(UInt8(min(31,Int(radius*32))))
            }
        }
        let count=(width*height+255)/256
        guard let b=geometry.withUnsafeBytes({device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared)}),
              let p=device.makeBuffer(length:count*32*16,options:.storageModeShared),
              let o=device.makeBuffer(length:32*16,options:.storageModeShared) else {throw LabError.io("GPU 暗角统计内存不足，请减小照片尺寸")}
        self.width=width;self.height=height;segments=count;bins=b;partials=p;output=o
    }
    func encode(_ image:MTLTexture,command:MTLCommandBuffer,region:Region=Region()) throws {
        try region.validate()
        let x=Int(region.x*Double(image.width)),y=Int(region.y*Double(image.height))
        let w=min(image.width-x,Int(region.width*Double(image.width))),h=min(image.height-y,Int(region.height*Double(image.height)))
        guard w>=16,h>=16 else {throw LabError.measurement("测量选区至少需要 16 × 16 像素，请扩大选区")}
        try prepare(width:w,height:h)
        var geometry=SIMD4<UInt32>(UInt32(x),UInt32(y),UInt32(w),UInt32(h))
        for (pipeline,count) in [(partialPipeline,segments),(reducePipeline,32)] {
            try Task.checkCancellation()
            guard let encoder=command.makeComputeCommandEncoder() else {throw LabError.io("无法创建 GPU 暗角测量任务")}
            encoder.label=pipeline === partialPipeline ? "CCDLab radial partial sums":"CCDLab radial reduction"
            encoder.setComputePipelineState(pipeline);encoder.setTexture(image,index:0)
            encoder.setBuffer(bins,offset:0,index:0);encoder.setBuffer(partials,offset:0,index:1);encoder.setBuffer(output,offset:0,index:2)
            var n=UInt32(segments);encoder.setBytes(&n,length:4,index:3)
            encoder.setBytes(&geometry,length:16,index:4)
            encoder.dispatchThreads(MTLSize(width:count,height:1,depth:1),threadsPerThreadgroup:MTLSize(width:32,height:1,depth:1));encoder.endEncoding()
        }
    }
    func read() throws -> RadialStatistics {
        guard let output else{throw LabError.io("GPU 暗角测量尚未完成")}
        let values=output.contents().bindMemory(to:SIMD4<Float>.self,capacity:32)
        var radial=[Double](),encodedSum=0.0,count=0.0
        for i in 0..<32 {
            guard values[i].x.isFinite,values[i].z.isFinite else {throw LabError.measurement("GPU 暗角统计无效")}
            radial.append(values[i].y>0 ? Double(values[i].x)/Double(values[i].y):.nan)
            encodedSum += Double(values[i].z);count += Double(values[i].y)
        }
        // Match the CPU definition for sparsely populated annuli, including unusual aspect ratios.
        for i in radial.indices where !radial[i].isFinite {
            let left=(0..<i).reversed().first{radial[$0].isFinite},right=((i+1)..<radial.count).first{radial[$0].isFinite}
            if let l=left,let r=right {radial[i]=radial[l]+(radial[r]-radial[l])*Double(i-l)/Double(r-l)}
            else {radial[i]=left.map{radial[$0]} ?? right.map{radial[$0]} ?? 0}
        }
        let center=radial.prefix(3).reduce(0,+)/3
        guard center>1e-6 else {throw LabError.measurement("平场中心太暗，无法可靠比较暗角；请提高拍摄曝光并避免过曝")}
        return RadialStatistics(radial:radial.map{$0/center},mean:encodedSum/max(1,count))
    }
    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    float3 radialDecode(float3 c) {return select(pow((c+0.055f)/1.055f,float3(2.4f)),c/12.92f,c<=0.04045f);}
    kernel void radialPartial(texture2d<float,access::read> src[[texture(0)]],
      const device uchar* bins[[buffer(0)]],device float4* partials[[buffer(1)]],
      constant uint& segments[[buffer(3)]],constant uint4& g[[buffer(4)]],uint id[[thread_position_in_grid]]) {
      if(id>=segments)return;
      float2 sums[32]={0},corrections[32]={0};uint counts[32]={0};
      uint end=min((id+1)*256,g.z*g.w);
      for(uint i=id*256;i<end;i++) {
        uint b=bins[i];float3 rgb=src.read(uint2(i%g.z+g.x,i/g.z+g.y)).rgb;
        float3 weights=float3(0.2126f,0.7152f,0.0722f);
        float2 value=float2(dot(radialDecode(rgb),weights),dot(rgb,weights));
        float2 adjusted=value-corrections[b],next=sums[b]+adjusted;
        corrections[b]=(next-sums[b])-adjusted;sums[b]=next;counts[b]++;
      }
      for(uint b=0;b<32;b++)partials[id*32+b]=float4(sums[b].x,float(counts[b]),sums[b].y,0);
    }
    kernel void radialReduce(const device float4* partials[[buffer(1)]],device float4* output[[buffer(2)]],
      constant uint& segments[[buffer(3)]],uint bin[[thread_position_in_grid]]) {
      if(bin>=32)return;float2 sum=0,correction=0;float count=0;
      for(uint i=0;i<segments;i++) {float4 p=partials[i*32+bin];float2 adjusted=p.xz-correction,next=sum+adjusted;correction=(next-sum)-adjusted;sum=next;count+=p.y;}
      output[bin]=float4(sum.x,count,sum.y,0);
    }
    """
}
