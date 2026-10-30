import ImageRendering
import Foundation
import Metal
import ImagingCore

/// Shared GPU glow measurement for calibration and developer checks.
final class GPUGlowMeasurement {
    private let device:MTLDevice,queue:MTLCommandQueue
    private var pipelines:[String:MTLComputePipelineState]=[:]
    private var buffers:[String:MTLBuffer]=[:]
    private var submissions=0,readback=0,gpuSeconds=0.0
    var cachedBufferBytes:Int {buffers.values.reduce(0){$0+$1.length}}
    func releaseCaches() {buffers.removeAll()}
    init(device:MTLDevice) throws {
        self.device=device
        guard let queue=device.makeCommandQueue() else{throw LabError.noMetal};self.queue=queue
        let options=MTLCompileOptions();options.fastMathEnabled=false
        let library=try device.makeLibrary(source:Self.shader,options:options)
        for name in ["prepareGlow","summaryGlow","quantileGlow","quantileReduceGlow","centerGlow","centerReduceGlow","binsGlow","binsReduceGlow","energyGlow","crossGlow"] {
            guard let f=library.makeFunction(name:name) else{throw LabError.io("缺少 GPU 光晕测量函数")}
            pipelines[name]=try device.makeComputePipelineState(function:f)
        }
    }
    private func buffer(_ key:String,_ bytes:Int)throws->MTLBuffer {
        if let b=buffers[key],b.length>=bytes{return b}
        guard let b=device.makeBuffer(length:max(16,bytes),options:.storageModeShared) else{throw LabError.io("GPU 光晕测量内存不足")}
        buffers[key]=b;return b
    }
    private func run(_ names:[(String,Int)],texture:MTLTexture,p:[UInt32],f:[Float],values:MTLBuffer,partials:MTLBuffer,out:MTLBuffer,hist:MTLBuffer,bins:MTLBuffer) throws {
        try Task.checkCancellation()
        guard let cmd=queue.makeCommandBuffer() else{throw LabError.noMetal}
        cmd.label="CCDLab GPU glow measurement"
        for (name,count) in names {
            guard let enc=cmd.makeComputeCommandEncoder(),let pipeline=pipelines[name] else{throw LabError.noMetal}
            enc.label=name;enc.setComputePipelineState(pipeline);enc.setTexture(texture,index:0)
            for (i,b) in [values,partials,out,hist,bins].enumerated(){enc.setBuffer(b,offset:0,index:i)}
            p.withUnsafeBytes{enc.setBytes($0.baseAddress!,length:$0.count,index:7)}
            f.withUnsafeBytes{enc.setBytes($0.baseAddress!,length:$0.count,index:6)}
            if name=="quantileGlow" {enc.dispatchThreadgroups(MTLSize(width:count,height:1,depth:1),threadsPerThreadgroup:MTLSize(width:256,height:1,depth:1))}
            else {enc.dispatchThreads(MTLSize(width:count,height:1,depth:1),threadsPerThreadgroup:MTLSize(width:min(32,pipeline.maxTotalThreadsPerThreadgroup),height:1,depth:1))}
            enc.endEncoding()
        }
        try Task.checkCancellation();cmd.commit();cmd.waitUntilCompleted()
        if let error=cmd.error{throw error}
        submissions+=1
        if cmd.gpuStartTime>0 {gpuSeconds+=max(0,cmd.gpuEndTime-cmd.gpuStartTime)}
        try Task.checkCancellation()
    }
    private func floats(_ b:MTLBuffer,_ n:Int)->[Double] {
        readback+=n*4;let v=b.contents().bindMemory(to:Float.self,capacity:n)
        return (0..<n).map{Double(v[$0])}
    }
    func measure(_ texture:MTLTexture,region:Region,scale:Double=1) throws -> GPUFeatureStatistics {
        try Task.checkCancellation();try region.validate()
        guard scale.isFinite,(0.05...20).contains(scale) else{throw LabError.measurement("参考图像素换算比例应在 0.05–20 之间")}
        let x=Int(region.x*Double(texture.width)),y=Int(region.y*Double(texture.height))
        let w=min(texture.width-x,Int(region.width*Double(texture.width))),h=min(texture.height-y,Int(region.height*Double(texture.height)))
        guard w>=16,h>=16 else{throw LabError.measurement("测量选区至少需要 16 × 16 像素，请扩大选区")}
        submissions=0;readback=0;gpuSeconds=0
        let n=w*h,segments=(n+255)/256,qSegments=(n+4095)/4096,binSegments=(n+2047)/2048
        let radius=Double(min(w,h))/2,binCount=min(512,max(32,Int(radius*2)))
        let values=try buffer("values",n*4),partials=try buffer("partials",segments*16)
        let out=try buffer("out",max(w,1024)*4),hist=try buffer("hist",qSegments*256*4),bins=try buffer("bins",binSegments*binCount*8)
        var p=[UInt32(x),UInt32(y),UInt32(w),UInt32(h),UInt32(segments),24,0,UInt32(binCount)]
        var f=[Float](repeating:0,count:8)
        func dispatch(_ tasks:[(String,Int)])throws {try run(tasks,texture:texture,p:p,f:f,values:values,partials:partials,out:out,hist:hist,bins:bins)}
        try dispatch([("prepareGlow",segments),("summaryGlow",1)])
        let initial=floats(out,2),mean=initial[0],peak=initial[1]
        var rank=UInt32(n/4),prefix:UInt32=0
        for shift in stride(from:24,through:0,by:-8) {
            p[4]=UInt32(qSegments);p[5]=UInt32(shift);p[6]=prefix
            try dispatch([("quantileGlow",qSegments),("quantileReduceGlow",256)])
            let counts=out.contents().bindMemory(to:UInt32.self,capacity:256);readback+=1024
            var selected:UInt32=0
            for b in 0..<256 {if rank<counts[b]{selected=UInt32(b);break};rank-=counts[b]}
            prefix=(prefix<<8)|selected
        }
        let background=Double(Float(bitPattern:prefix))
        guard peak-background>0.05 else{throw LabError.measurement("亮源与背景的反差不足，请使用暗背景中的孤立亮源")}
        f[0]=Float(background);f[1]=Float(peak);p[4]=UInt32(segments)
        try dispatch([("centerGlow",segments),("centerReduceGlow",1)])
        let moments=floats(out,3),cx=Double(w)/2+moments[0]/max(moments[2],1e-12),cy=Double(h)/2+moments[1]/max(moments[2],1e-12)
        guard cx>=2,cy>=2,cx<Double(w-2),cy<Double(h-2) else{throw LabError.measurement("亮源太靠近选区边缘，请重新框选，使亮源居中并包含完整光晕")}
        f[2]=Float(cx);f[3]=Float(cy);f[4]=Float(radius)
        // Preserve subpixel offsets smaller than a Float ULP at the absolute center.
        f[5]=Float(cx-Double(f[2]));f[6]=Float(cy-Double(f[3]))
        p[4]=UInt32(binSegments);p[6]=UInt32(min(h-1,Int(cy)))
        try dispatch([("binsGlow",binSegments),("energyGlow",1)])
        let totals=floats(out,2),energy=totals[0],moment=totals[1]
        guard energy>0 else{throw LabError.measurement("选区没有可测量的亮源扩散，请检查亮源和背景")}
        try dispatch([("binsReduceGlow",binCount)])
        let radialStats=floats(out,binCount*2)
        var radial=[Double](),energies=[Double]()
        for b in 0..<binCount {radial.append(radialStats[b*2]/max(1,radialStats[b*2+1])/max(peak-background,1e-9));energies.append(radialStats[b*2]/energy)}
        try dispatch([("crossGlow",w)])
        let cross=floats(out,w)
        var total=0.0
        return GPUFeatureStatistics(metrics:["centerX":cx+Double(x),"centerY":cy+Double(y),"mean":mean,"background":background,"peak":peak,"energy":energy,"spread":sqrt(moment/energy)*scale],curves:["radial":radial,"energy":energies,"encircled":energies.map{total+=$0;return total},"radiusPixels":(0..<binCount).map{Double($0+1)*radius/Double(binCount)*scale},"crossSection":cross],warnings:["测得的扩散也包含光源自身大小、曝光截断和镜头效果；两图须使用大小、曝光和拍摄条件可比的孤立亮源。"],width:w,height:h,readbackBytes:readback,submissions:submissions,gpuSeconds:gpuSeconds)
    }
    private static let shader="""
    #include <metal_stdlib>
    using namespace metal;
    float glowLinear(float c){return c<=0.04045f ? c/12.92f:pow((c+0.055f)/1.055f,2.4f);}
    void glowAdd(thread float& s,thread float& c,float v){float a=v-c,t=s+a;c=(t-s)-a;s=t;}
    void glowAdd3(thread float3& s,thread float3& c,float3 v){float3 a=v-c,t=s+a;c=(t-s)-a;s=t;}
    kernel void prepareGlow(texture2d<float,access::read> src[[texture(0)]],device float* values[[buffer(0)]],device float4* partials[[buffer(1)]],constant uint* p[[buffer(7)]],uint id[[thread_position_in_grid]]) {
      if(id>=p[4])return;float sum=0,c=0,peak=-INFINITY;uint n=p[2]*p[3];
      for(uint i=id*256;i<min(n,(id+1)*256);i++){
        float3 rgb=src.read(uint2(p[0]+i%p[2],p[1]+i/p[2])).rgb;
        float encoded=dot(rgb,float3(0.2126f,0.7152f,0.0722f));
        float value=dot(float3(glowLinear(rgb.r),glowLinear(rgb.g),glowLinear(rgb.b)),float3(0.2126f,0.7152f,0.0722f));
        values[i]=value;glowAdd(sum,c,encoded);peak=max(peak,value);
      }partials[id]=float4(sum,peak,0,0);
    }
    kernel void summaryGlow(const device float4* partials[[buffer(1)]],device float* out[[buffer(2)]],constant uint* p[[buffer(7)]],uint id[[thread_position_in_grid]]){
      if(id)return;float sum=0,c=0,peak=-INFINITY;for(uint i=0;i<p[4];i++){glowAdd(sum,c,partials[i].x);peak=max(peak,partials[i].y);}out[0]=sum/float(p[2]*p[3]);out[1]=peak;
    }
    kernel void quantileGlow(const device float* values[[buffer(0)]],device uint* hist[[buffer(3)]],constant uint* p[[buffer(7)]],uint group[[threadgroup_position_in_grid]],uint tid[[thread_index_in_threadgroup]]){
      threadgroup atomic_uint buckets[256];atomic_store_explicit(&buckets[tid],0,memory_order_relaxed);threadgroup_barrier(mem_flags::mem_threadgroup);
      uint n=p[2]*p[3];for(uint i=group*4096+tid;i<min(n,(group+1)*4096);i+=256){uint bits=as_type<uint>(values[i]);if(p[5]==24 || (bits>>(p[5]+8))==p[6])atomic_fetch_add_explicit(&buckets[(bits>>p[5])&255],1,memory_order_relaxed);}
      threadgroup_barrier(mem_flags::mem_threadgroup);hist[group*256+tid]=atomic_load_explicit(&buckets[tid],memory_order_relaxed);
    }
    kernel void quantileReduceGlow(const device uint* hist[[buffer(3)]],device uint* out[[buffer(2)]],constant uint* p[[buffer(7)]],uint id[[thread_position_in_grid]]){if(id>=256)return;uint count=0;for(uint i=0;i<p[4];i++)count+=hist[i*256+id];out[id]=count;}
    kernel void centerGlow(const device float* values[[buffer(0)]],device float4* partials[[buffer(1)]],constant float* f[[buffer(6)]],constant uint* p[[buffer(7)]],uint id[[thread_position_in_grid]]){
      if(id>=p[4])return;float3 sum=0,c=0;float threshold=f[0]+0.9f*(f[1]-f[0]);uint n=p[2]*p[3];
      for(uint i=id*256;i<min(n,(id+1)*256);i++){float v=max(0.0f,values[i]-threshold);glowAdd3(sum,c,float3(v*(float(i%p[2])-float(p[2])*0.5f),v*(float(i/p[2])-float(p[3])*0.5f),v));}partials[id]=float4(sum,0);
    }
    kernel void centerReduceGlow(const device float4* partials[[buffer(1)]],device float* out[[buffer(2)]],constant uint* p[[buffer(7)]],uint id[[thread_position_in_grid]]){if(id)return;float3 sum=0,c=0;for(uint i=0;i<p[4];i++)glowAdd3(sum,c,partials[i].xyz);out[0]=sum.x;out[1]=sum.y;out[2]=sum.z;}
    kernel void binsGlow(const device float* values[[buffer(0)]],device float4* partials[[buffer(1)]],device float2* bins[[buffer(4)]],constant float* f[[buffer(6)]],constant uint* p[[buffer(7)]],uint id[[thread_position_in_grid]]){
      if(id>=p[4])return;float sums[512]={0},corrections[512]={0};uint counts[512]={0};float energy=0,ec=0,moment=0,mc=0;uint n=p[2]*p[3];
      for(uint i=id*2048;i<min(n,(id+1)*2048);i++){
        float dx=(float(i%p[2])-f[2])-f[5],dy=(float(i/p[2])-f[3])-f[6],dist=sqrt(dx*dx+dy*dy);if(dist>=f[4])continue;
        float v=max(0.0f,values[i]-f[0]);uint b=min(p[7]-1,uint(floor(dist/f[4]*float(p[7])+1e-9f)));
        glowAdd(sums[b],corrections[b],v);counts[b]++;glowAdd(energy,ec,v);glowAdd(moment,mc,v*dist*dist);
      }
      for(uint b=0;b<p[7];b++)bins[id*p[7]+b]=float2(sums[b],float(counts[b]));partials[id]=float4(energy,moment,0,0);
    }
    kernel void energyGlow(const device float4* partials[[buffer(1)]],device float* out[[buffer(2)]],constant uint* p[[buffer(7)]],uint id[[thread_position_in_grid]]){if(id)return;float3 sum=0,c=0;for(uint i=0;i<p[4];i++)glowAdd3(sum,c,partials[i].xyz);out[0]=sum.x;out[1]=sum.y;}
    kernel void binsReduceGlow(const device float2* bins[[buffer(4)]],device float2* out[[buffer(2)]],constant uint* p[[buffer(7)]],uint id[[thread_position_in_grid]]){if(id>=p[7])return;float sum=0,c=0,count=0;for(uint i=0;i<p[4];i++){float2 v=bins[i*p[7]+id];glowAdd(sum,c,v.x);count+=v.y;}out[id]=float2(sum,count);}
    kernel void crossGlow(const device float* values[[buffer(0)]],device float* out[[buffer(2)]],constant float* f[[buffer(6)]],constant uint* p[[buffer(7)]],uint id[[thread_position_in_grid]]){if(id>=p[2])return;out[id]=(values[p[6]*p[2]+id]-f[0])/max(f[1]-f[0],1e-9f);}
    """
}
