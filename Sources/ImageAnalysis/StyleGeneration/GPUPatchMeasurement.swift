import Foundation
import Metal
import ImagingCore

/// Projects each original pixel into board coordinates; no geometric resampling or CPU pixel readback.
final class GPUPatchMeasurement {
    let device:MTLDevice,queue:MTLCommandQueue,partial:MTLComputePipelineState,reduce:MTLComputePipelineState
    init(device:MTLDevice) throws {
        self.device=device
        guard let queue=device.makeCommandQueue() else {throw LabError.noMetal};self.queue=queue
        let options=MTLCompileOptions();options.fastMathEnabled=false
        let library=try device.makeLibrary(source:Self.shader,options:options)
        guard let a=library.makeFunction(name:"patchPartial"),let b=library.makeFunction(name:"patchReduce") else {throw LabError.noMetal}
        partial=try device.makeComputePipelineState(function:a);reduce=try device.makeComputePipelineState(function:b)
    }
    func measure(_ texture:MTLTexture,transform:ProjectiveTransform,regions:[TargetRegion]) throws -> [PatchMeasurement] {
        try Task.checkCancellation()
        guard !regions.isEmpty,regions.count<=64 else {throw LabError.measurement("每幅图测量 1–64 个区域")}
        let inverse=try transform.inverted()
        var results=[PatchMeasurement]()
        for region in regions {
            try Task.checkCancellation()
            let corners=region.rect.corners.map(transform.project)
            guard corners.allSatisfy({$0.x.isFinite && $0.y.isFinite}),region.rect.width>0,region.rect.height>0 else {throw LabError.measurement("测量区域无效")}
            let x0=Int(max(0,min(Double(texture.width),floor(corners.map(\.x).min()!)))),y0=Int(max(0,min(Double(texture.height),floor(corners.map(\.y).min()!))))
            let x1=Int(max(0,min(Double(texture.width),ceil(corners.map(\.x).max()!)))),y1=Int(max(0,min(Double(texture.height),ceil(corners.map(\.y).max()!))))
            guard x1>x0,y1>y0 else {throw LabError.measurement("测量区域位于图像以外")}
            let count=(x1-x0)*(y1-y0),groups=(count+255)/256
            guard let partials=device.makeBuffer(length:groups*32,options:.storageModePrivate),
                  let output=device.makeBuffer(length:32,options:.storageModeShared),let cmd=queue.makeCommandBuffer(),
                  let encoder=cmd.makeComputeCommandEncoder() else {throw LabError.noMetal}
            var bounds=SIMD4<UInt32>(UInt32(x0),UInt32(y0),UInt32(x1-x0),UInt32(y1-y0))
            var rect=SIMD4<Float>(Float(region.rect.x),Float(region.rect.y),Float(region.rect.width),Float(region.rect.height))
            let matrix=inverse.coefficients.map(Float.init)
            encoder.setComputePipelineState(partial);encoder.setTexture(texture,index:0);encoder.setBuffer(partials,offset:0,index:0)
            encoder.setBytes(&bounds,length:16,index:1);encoder.setBytes(&rect,length:16,index:2)
            matrix.withUnsafeBytes{encoder.setBytes($0.baseAddress!,length:$0.count,index:3)}
            encoder.dispatchThreadgroups(MTLSize(width:groups,height:1,depth:1),threadsPerThreadgroup:MTLSize(width:256,height:1,depth:1))
            encoder.setComputePipelineState(reduce);encoder.setBuffer(output,offset:0,index:1)
            var n=UInt32(groups);encoder.setBytes(&n,length:4,index:2)
            encoder.dispatchThreads(MTLSize(width:1,height:1,depth:1),threadsPerThreadgroup:MTLSize(width:1,height:1,depth:1));encoder.endEncoding()
            cmd.commit();cmd.waitUntilCompleted();if let error=cmd.error {throw error};try Task.checkCancellation()
            let values=output.contents().bindMemory(to:SIMD4<Float>.self,capacity:2),nPixels=Double(values[0].w)
            guard nPixels>=1 else {throw LabError.measurement("测量区域内没有原始像素")}
            let mean=(0..<3).map{Double(values[0][$0])/nPixels}
            let variance=(0..<3).map{max(0,Double(values[1][$0])/nPixels-mean[$0]*mean[$0])}
            results.append(.init(id:region.id,kind:region.kind,mean:mean,variance:variance,clippedFraction:Double(values[1].w)/nPixels,pixelCount:Int(nPixels)))
        }
        return results
    }
    private static let shader="""
    #include <metal_stdlib>
    using namespace metal;
    struct Stats {float4 sum;float4 square;};
    kernel void patchPartial(texture2d<float,access::read> image [[texture(0)]],device Stats* out [[buffer(0)]],
      constant uint4& box [[buffer(1)]],constant float4& rect [[buffer(2)]],constant float* h [[buffer(3)]],
      uint i [[thread_position_in_grid]],uint t [[thread_index_in_threadgroup]],uint group [[threadgroup_position_in_grid]]) {
      threadgroup float4 sums[256];threadgroup float4 squares[256];
      float4 s=0,q=0;
      if(i<box.z*box.w) {
        uint2 p=uint2(box.x+i%box.z,box.y+i/box.z);float x=p.x+0.5f,y=p.y+0.5f;
        float w=h[6]*x+h[7]*y+h[8];float2 b=float2(h[0]*x+h[1]*y+h[2],h[3]*x+h[4]*y+h[5])/w;
        if(all(b>=rect.xy) && all(b<rect.xy+rect.zw)) {
          float3 v=image.read(p).rgb;s=float4(v,1);q=float4(v*v,any(v<=0.002f)||any(v>=0.998f) ? 1.0f:0.0f);
        }
      }
      sums[t]=s;squares[t]=q;threadgroup_barrier(mem_flags::mem_threadgroup);
      for(uint stride=128;stride>0;stride/=2) {if(t<stride){sums[t]+=sums[t+stride];squares[t]+=squares[t+stride];}threadgroup_barrier(mem_flags::mem_threadgroup);}
      if(t==0){out[group].sum=sums[0];out[group].square=squares[0];}
    }
    kernel void patchReduce(device const Stats* src [[buffer(0)]],device Stats* dst [[buffer(1)]],constant uint& n [[buffer(2)]]) {
      float4 s=0,q=0;for(uint i=0;i<n;i++){s+=src[i].sum;q+=src[i].square;}dst[0].sum=s;dst[0].square=q;
    }
    """
}
