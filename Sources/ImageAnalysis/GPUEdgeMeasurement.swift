import ImageRendering
import Foundation
import Metal
import ImagingCore

/// Shared GPU edge measurement for calibration and developer checks.
/// Pixel scans, exact float radix selection and ESF bins stay on the GPU. Only
/// histograms, row summaries and the 128-bin curve cross back to the CPU.
final class GPUEdgeMeasurement {
    private let device:MTLDevice,queue:MTLCommandQueue
    private let pipelines:[String:MTLComputePipelineState]
    init(device:MTLDevice) throws {
        self.device=device
        guard let queue=device.makeCommandQueue() else {throw LabError.io("无法创建 GPU 边缘测量队列")}
        self.queue=queue
        let options=MTLCompileOptions();options.fastMathEnabled=false
        let library=try device.makeLibrary(source:Self.shader,options:options)
        var states=[String:MTLComputePipelineState]()
        for name in ["edgeExtract","edgeHistogram","edgePositions","edgeBins","edgeReduce"] {
            guard let function=library.makeFunction(name:name) else {throw LabError.io("缺少 GPU 边缘测量函数")}
            states[name]=try device.makeComputePipelineState(function:function)
        }
        pipelines=states
    }
    func measure(_ texture:MTLTexture,region:Region,scale:Double=1) throws -> GPUFeatureStatistics {
        try Task.checkCancellation();try region.validate()
        guard scale.isFinite,(0.05...20).contains(scale) else {throw LabError.measurement("参考图像素换算比例应在 0.05–20 之间")}
        let x0=Int(region.x*Double(texture.width)),y0=Int(region.y*Double(texture.height))
        let width=min(texture.width-x0,Int(region.width*Double(texture.width)))
        let height=min(texture.height-y0,Int(region.height*Double(texture.height)))
        guard width>=16,height>=16 else {throw LabError.measurement("测量选区至少需要 16 × 16 像素，请扩大选区")}
        let count=try ImageDimensions.pixelCount(width:width,height:height)
        guard count<=Int(UInt32.max)-255 else {throw LabError.measurement("测量选区超过 GPU 32 位索引范围")}
        let segments=(count+255)/256
        func buffer(_ length:Int,_ shared:Bool=false) throws -> MTLBuffer {
            guard length<=device.maxBufferLength,let value=device.makeBuffer(length:length,options:shared ? .storageModeShared:.storageModePrivate) else {throw LabError.io("GPU 边缘统计内存不足，请减小照片尺寸")}
            return value
        }
        let pixels=try buffer(count*8),rows=try buffer(max(width,height)*16,true)
        let histogram=try buffer(512*4,true),partials=try buffer(segments*128*8),output=try buffer(128*8,true)
        var geometry=SIMD4<UInt32>(UInt32(x0),UInt32(y0),UInt32(width),UInt32(height))
        var selection=SIMD4<UInt32>(0,0,0,24)
        var orientation=SIMD4<UInt32>(0,UInt32(width),UInt32(height),UInt32(segments))
        var coefficients=[SIMD2<Float>](repeating:.zero,count:6)
        var submissions=0,readback=0,gpuSeconds=0.0
        func run(_ jobs:[(String,Int)],clearHistogram:Bool=false) throws {
            try Task.checkCancellation()
            guard let command=queue.makeCommandBuffer() else {throw LabError.io("无法创建 GPU 边缘测量任务")}
            command.label="CCDLab GPU edge measurement"
            if clearHistogram {
                guard let blit=command.makeBlitCommandEncoder() else {throw LabError.io("无法清空 GPU 边缘直方图")}
                blit.fill(buffer:histogram,range:0..<histogram.length,value:0);blit.endEncoding()
            }
            for (name,n) in jobs {
                guard let encoder=command.makeComputeCommandEncoder(),let pipeline=pipelines[name] else {throw LabError.io("无法编码 GPU 边缘测量")}
                encoder.label=name;encoder.setComputePipelineState(pipeline);encoder.setTexture(texture,index:0)
                for (index,value) in [pixels,rows,histogram,partials,output].enumerated() {encoder.setBuffer(value,offset:0,index:index)}
                encoder.setBytes(&geometry,length:16,index:5);encoder.setBytes(&selection,length:16,index:6)
                encoder.setBytes(&orientation,length:16,index:7)
                coefficients.withUnsafeBytes{encoder.setBytes($0.baseAddress!,length:$0.count,index:8)}
                encoder.dispatchThreads(MTLSize(width:n,height:1,depth:1),threadsPerThreadgroup:MTLSize(width:min(64,pipeline.maxTotalThreadsPerThreadgroup),height:1,depth:1))
                encoder.endEncoding()
            }
            command.commit();command.waitUntilCompleted()
            guard command.status == .completed else {throw LabError.io("GPU 边缘测量失败：\(command.error?.localizedDescription ?? "未知错误")")}
            submissions+=1;gpuSeconds+=max(0,command.gpuEndTime-command.gpuStartTime)
            try Task.checkCancellation()
        }
        try run([("edgeExtract",height)])
        let summary=rows.contents().bindMemory(to:SIMD4<Float>.self,capacity:height)
        var sum=0.0,dx=0.0,dy=0.0
        for y in 0..<height {sum+=Double(summary[y].x);dx+=Double(summary[y].y);dy+=Double(summary[y].z)}
        readback+=height*16
        let transpose=dy>dx,w=transpose ? height:width,h=transpose ? width:height
        orientation=SIMD4<UInt32>(transpose ? 1:0,UInt32(w),UInt32(h),UInt32(segments))
        // Four byte-wise radix passes preserve the exact index convention without
        // allocating a padded full-image sort. Signed floats use monotonic keys.
        var ranks=[UInt32(count/10),UInt32(count*9/10)],prefix=[UInt32](repeating:0,count:2),mask:UInt32=0
        for shift in [24,16,8,0] {
            selection=SIMD4<UInt32>(prefix[0],prefix[1],mask,UInt32(shift))
            try run([("edgeHistogram",count)],clearHistogram:true)
            let bins=histogram.contents().bindMemory(to:UInt32.self,capacity:512)
            for q in 0..<2 {
                var bucket=0
                while bucket<255 && ranks[q]>=bins[q*256+bucket] {ranks[q]-=bins[q*256+bucket];bucket+=1}
                prefix[q] |= UInt32(bucket)<<UInt32(shift)
            }
            mask |= UInt32(255)<<UInt32(shift);readback+=2048
        }
        func value(_ key:UInt32)->Double {Double(Float(bitPattern:key & 0x80000000 != 0 ? key ^ 0x80000000 : ~key))}
        let low=value(prefix[0]),high=value(prefix[1]),contrast=high-low
        guard contrast>0.05,w>=32,h>=32 else {throw LabError.measurement("边缘选区至少需要 32 × 32 像素，明暗灰阶差需大于 0.05（0–1 标度）；请扩大选区或选择更清晰的边缘")}
        try run([("edgePositions",h)])
        let positions=rows.contents().bindMemory(to:SIMD4<Float>.self,capacity:h)
        let center=(0..<h).reduce(0.0){$0+Double(positions[$1].x)+Double(positions[$1].y)}/Double(h)
        let hy=Double(h-1)/2
        var numerator=0.0,denominator=0.0,endDifference=0.0
        for y in 0..<h {
            let relative=Double(y)-hy
            numerator+=relative*(Double(positions[y].x)+Double(positions[y].y)-center)
            denominator+=relative*relative;endDifference+=Double(positions[y].z)
        }
        readback+=h*16
        let slope=numerator/max(denominator,1)
        guard abs(slope)>=0.015,abs(slope)<0.3,center>8,center<Double(w-8) else {throw LabError.measurement("请框选单一的直线边缘，相对水平或垂直倾斜约 1–15°，放在选区中央并在两侧留出平坦区域")}
        func split(_ x:Double)->SIMD2<Float> {let f=Float(x);return SIMD2(f,Float(x-Double(f)))}
        coefficients=[split(center),split(slope),split(hy),split(endDifference>0 ? scale:-scale),split(low),split(contrast)]
        try run([("edgeBins",segments),("edgeReduce",128)])
        let bins=output.contents().bindMemory(to:SIMD2<Float>.self,capacity:128)
        var esf=(0..<128).map{bins[$0].y>0 ? Double(bins[$0].x)/Double(bins[$0].y):Double.nan}
        readback+=128*8
        for i in esf.indices where !esf[i].isFinite {
            let left=(0..<i).reversed().first{esf[$0].isFinite},right=((i+1)..<esf.count).first{esf[$0].isFinite}
            if let l=left,let r=right {esf[i]=esf[l]+(esf[r]-esf[l])*Double(i-l)/Double(r-l)}
            else {esf[i]=left.map{esf[$0]} ?? right.map{esf[$0]} ?? 0}
        }
        // Small 128-sample curve math is deliberately CPU-side, matching the
        // diagnostic's original Hamming window and uncompensated derivative.
        var lsf=(1..<127).map{(esf[$0+1]-esf[$0-1])*0.5}
        for i in lsf.indices {lsf[i]*=0.54-0.46*cos(2*Double.pi*Double(i)/Double(lsf.count-1))}
        let dc=max(1e-12,abs(lsf.reduce(0,+)))
        let mtf=(0...64).map{k -> Double in
            var re=0.0,im=0.0
            for i in lsf.indices {let angle=2*Double.pi*Double(k)/128*Double(i)/4;re+=lsf[i]*cos(angle);im-=lsf[i]*sin(angle)}
            return hypot(re,im)/dc
        }
        var mtf50=0.5
        for i in 1..<mtf.count where mtf[i]<=0.5 {mtf50=(Double(i-1)+(mtf[i-1]-0.5)/max(1e-12,mtf[i-1]-mtf[i]))/128;break}
        try Task.checkCancellation()
        return GPUFeatureStatistics(metrics:["mean":sum/Double(count),"mtf50":mtf50,"overshoot":max(0,(esf.max() ?? 1)-1),"undershoot":max(0,-(esf.min() ?? 0)),"slope":slope,"contrast":contrast],curves:["edge":esf,"mtf":mtf],warnings:["斜边响应仅用于两图诊断比较，未做导数补偿，不等同于符合 ISO 的镜头分辨率测量。"],width:width,height:height,readbackBytes:readback,submissions:submissions,gpuSeconds:gpuSeconds)
    }
    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    // Double-single arithmetic retains low bits for geometry near bin boundaries.
    float2 ea(float2 a,float2 b) {float s=a.x+b.x,v=s-a.x,e=(a.x-(s-v))+(b.x-v)+a.y+b.y;float h=s+e;return float2(h,e-(h-s));}
    float2 en(float2 a) {return -a;}
    float2 em(float2 a,float2 b) {float p=a.x*b.x,e=fma(a.x,b.x,-p)+a.x*b.y+a.y*b.x;float h=p+e;return float2(h,e-(h-p));}
    float2 ed(float2 a,float2 b) {float q=a.x/b.x;float2 r=ea(a,en(em(b,float2(q,0))));return ea(float2(q,0),float2((r.x+r.y)/b.x,0));}
    float2 eabs(float2 a) {return a.x<0 ? -a:a;}
    float2 luminance(float3 c) {
      return ea(ea(em(float2(c.r,0),float2(0.2126f,7.247924816e-9f)),em(float2(c.g,0),float2(0.7152f,-6.961822563e-9f))),em(float2(c.b,0),float2(0.0722f,-2.861022946e-10f)));
    }
    float2 oriented(const device float2* a,uint x,uint y,uint4 geo,uint4 o) {return a[o.x ? x*geo.z+y:y*geo.z+x];}
    kernel void edgeExtract(texture2d<float,access::read> src[[texture(0)]],device float2* a[[buffer(0)]],device float4* rows[[buffer(1)]],constant uint4& g[[buffer(5)]],uint y[[thread_position_in_grid]]) {
      if(y>=g.w)return;float2 sum=0,dx=0,dy=0,previous=0;
      for(uint x=0;x<g.z;x++) {float2 v=luminance(src.read(uint2(x+g.x,y+g.y)).rgb);a[y*g.z+x]=v;sum=ea(sum,v);
        if(x>0 && y>0) {dx=ea(dx,eabs(ea(v,-previous)));dy=ea(dy,eabs(ea(v,-luminance(src.read(uint2(x+g.x,y-1+g.y)).rgb))));}previous=v;}
      rows[y]=float4(sum.x+sum.y,dx.x+dx.y,dy.x+dy.y,0);
    }
    kernel void edgeHistogram(const device float2* a[[buffer(0)]],device atomic_uint* hist[[buffer(2)]],constant uint4& g[[buffer(5)]],constant uint4& s[[buffer(6)]],uint id[[thread_position_in_grid]]) {
      if(id>=g.z*g.w)return;uint bits=as_type<uint>(a[id].x+a[id].y),key=(bits & 0x80000000u) ? ~bits:(bits ^ 0x80000000u);
      uint bucket=(key>>s.w)&255u;
      if((key&s.z)==s.x)atomic_fetch_add_explicit(hist+bucket,1u,memory_order_relaxed);
      if((key&s.z)==s.y)atomic_fetch_add_explicit(hist+256+bucket,1u,memory_order_relaxed);
    }
    kernel void edgePositions(const device float2* a[[buffer(0)]],device float4* rows[[buffer(1)]],constant uint4& g[[buffer(5)]],constant uint4& o[[buffer(7)]],uint y[[thread_position_in_grid]]) {
      if(y>=o.z)return;float2 sum=0,weight=0,first=oriented(a,0,y,g,o),previous=first;
      for(uint x=1;x<o.y;x++) {float2 v=oriented(a,x,y,g,o),d=eabs(ea(v,-previous));sum=ea(sum,em(d,float2(float(x)-0.5f,0)));weight=ea(weight,d);previous=v;}
      float2 position=ed(sum,weight.x>1e-10f ? weight:float2(1e-10f,0));
      rows[y]=float4(position,previous.x-first.x,0);
    }
    kernel void edgeBins(const device float2* a[[buffer(0)]],device float2* partials[[buffer(3)]],constant uint4& g[[buffer(5)]],constant uint4& o[[buffer(7)]],constant float2* c[[buffer(8)]],uint id[[thread_position_in_grid]]) {
      if(id>=o.w)return;float sums[128]={0},corrections[128]={0},counts[128]={0};
      uint end=min((id+1)*256,g.z*g.w);
      for(uint i=id*256;i<end;i++) {uint x=i%o.y,y=i/o.y;
        float2 distance=em(ea(ea(float2(float(x),0),-c[0]),-em(c[1],ea(float2(float(y),0),-c[2]))),c[3]);
        // Triangular accumulation at bin centers makes subpixel motion continuous.
        // Hard bin membership caused ESF jumps under 16-bit rounding, misleading inverse search.
        float2 location=ea(em(ea(distance,float2(16,0)),float2(4,0)),float2(-0.5f,0));
        float position=location.x+location.y;int base=int(floor(position));float fraction=position-float(base);
        float2 v=ed(ea(oriented(a,x,y,g,o),-c[4]),c[5]);
        for(int offset=0;offset<2;offset++) {int bin=base+offset;if(bin<0 || bin>=128)continue;
          float weight=offset==0 ? 1.0f-fraction:fraction;
          float adjusted=(v.x+v.y)*weight-corrections[bin],next=sums[bin]+adjusted;
          corrections[bin]=(next-sums[bin])-adjusted;sums[bin]=next;counts[bin]+=weight;
        }
      }
      for(uint b=0;b<128;b++)partials[id*128+b]=float2(sums[b],float(counts[b]));
    }
    kernel void edgeReduce(const device float2* partials[[buffer(3)]],device float2* output[[buffer(4)]],constant uint4& o[[buffer(7)]],uint b[[thread_position_in_grid]]) {
      if(b>=128)return;float2 sum=0,count=0;
      for(uint i=0;i<o.w;i++){float2 p=partials[i*128+b];sum=ea(sum,float2(p.x,0));count=ea(count,float2(p.y,0));}
      output[b]=float2(sum.x+sum.y,count.x+count.y);
    }
    """
}
