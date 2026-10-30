import Foundation
import Metal
import ImagingCore

struct LightSignature {
    var rgb:[Double],counts:[Double],peak:Double,background:Double,coreRadius:Double,centerX:Double,centerY:Double,clipped:Double,outside:Double,asymmetry:Double
    func validate()throws {
        guard rgb.count==768,counts.count==256,rgb.allSatisfy({$0.isFinite}),peak.isFinite,background.isFinite,coreRadius.isFinite,
              peak>0.1,peak<0.98,background<0.03,coreRadius>=1,coreRadius<24,clipped==0,outside<0.02,asymmetry<0.04 else {throw LabError.measurement("亮源不满足有效域：需未裁切孤立亮源、暗背景、完整且近圆形的扩散；鬼影和不规则亮源须人工处理")}
    }
    func error(to other:Self)->Double {
        let scale=max(0.05,other.peak-other.background)
        return sqrt(zip(rgb,other.rgb).map{pow(($0-$1)/scale,2)}.reduce(0,+)/Double(rgb.count))
    }
}
/// RGB sector/annulus reduction. Transfers only 1,032 scalars, never image pixels.
final class GPULightMeasurement {
    private let device:MTLDevice,queue:MTLCommandQueue,pipeline:MTLComputePipelineState
    private let summaryMeasurement:GPUGlowMeasurement
    init(device:MTLDevice)throws {
        self.device=device;summaryMeasurement=try GPUGlowMeasurement(device:device)
        guard let q=device.makeCommandQueue() else{throw LabError.noMetal};queue=q
        let library=try device.makeLibrary(source:Self.shader,options:nil)
        guard let f=library.makeFunction(name:"lightRings")else{throw LabError.noMetal};pipeline=try device.makeComputePipelineState(function:f)
    }
    func measure(_ texture:MTLTexture)throws->LightSignature {
        let summary=try summaryMeasurement.measure(texture,region:Region())
        let cx=summary.metrics["centerX"]!,cy=summary.metrics["centerY"]!,peak=summary.metrics["peak"]!,background=summary.metrics["background"]!
        let radius=min(128.0,Double(min(texture.width,texture.height))*0.25)
        guard cx>radius,cy>radius,cx<Double(texture.width)-radius,cy<Double(texture.height)-radius else{throw LabError.measurement("亮源及外圈暗背景必须完整位于画面内")}
        guard let out=device.makeBuffer(length:1032*4,options:.storageModeShared),let cmd=queue.makeCommandBuffer(),let enc=cmd.makeComputeCommandEncoder()else{throw LabError.noMetal}
        let parameters=[Float(cx),Float(cy),Float(radius),Float(background),Float(peak)]
        enc.setComputePipelineState(pipeline);enc.setTexture(texture,index:0);enc.setBuffer(out,offset:0,index:0)
        parameters.withUnsafeBytes{enc.setBytes($0.baseAddress!,length:$0.count,index:1)}
        enc.dispatchThreads(.init(width:257,height:1,depth:1),threadsPerThreadgroup:.init(width:32,height:1,depth:1));enc.endEncoding()
        try Task.checkCancellation();cmd.commit();cmd.waitUntilCompleted();if let error=cmd.error{throw error};try Task.checkCancellation()
        let p=out.contents().bindMemory(to:Float.self,capacity:1032)
        var rgb=[Double](),counts=[Double](),asymmetry=0.0
        for bin in 0..<64 {
            let values=(0..<4).map{s in (0..<3).map{Double(p[(bin*4+s)*4+$0])}}
            for s in 0..<4 {rgb+=values[s];counts.append(Double(p[(bin*4+s)*4+3]))}
            // Ignore undersampled central rings where pixel alignment dominates.
            if bin>3 && (0..<4).allSatisfy({p[(bin*4+$0)*4+3]>8}) {
                for c in 0..<3 {asymmetry=max(asymmetry,(values.map{$0[c]}.max()!-values.map{$0[c]}.min()!)/max(0.05,peak-background))}
            }
        }
        return .init(rgb:rgb,counts:counts,peak:peak,background:background,coreRadius:sqrt(Double(p[1024])/Double.pi),centerX:cx,centerY:cy,clipped:Double(p[1025]),outside:Double(p[1026]),asymmetry:asymmetry)
    }
    private static let shader="""
    #include <metal_stdlib>
    using namespace metal;
    float3 lightDecode(float3 x){return select(x/12.92f,pow((x+0.055f)/1.055f,float3(2.4f)),x>0.04045f);}
    kernel void lightRings(texture2d<float,access::read> src[[texture(0)]],device float* out[[buffer(0)]],constant float* p[[buffer(1)]],uint id[[thread_position_in_grid]]) {
      if(id>256)return;
      int2 lower=max(int2(0),int2(floor(float2(p[0],p[1])-p[2]))),upper=min(int2(src.get_width(),src.get_height()),int2(ceil(float2(p[0],p[1])+p[2])));
      float3 sum=0;uint n=0,clipped=0,core=0;float outside=0;
      if(id==256){lower=int2(0);upper=int2(src.get_width(),src.get_height());}
      uint bin=id/4,sector=id%4;
      for(int y=lower.y;y<upper.y;y++){for(int x=lower.x;x<upper.x;x++){
        float2 d=float2(x,y)-float2(p[0],p[1]);float radius=length(d);if(id<256 && radius>=p[2])continue;
        if(id<256 && (uint(radius/p[2]*64)!=bin || uint(d.x>=0)+2*uint(d.y>=0)!=sector))continue;
        float3 encoded=src.read(uint2(x,y)).rgb,v=lightDecode(encoded);
        if(id==256){core+=uint(dot(v,float3(.2126f,.7152f,.0722f))>p[3]+.9f*(p[4]-p[3]));clipped+=uint(any(encoded>=.99999f));if(radius>=p[2])outside=max(outside,max(v.r,max(v.g,v.b))-p[3]);}
        else{sum+=v;n++;}
      }}
      if(id==256){out[1024]=float(core);out[1025]=float(clipped);out[1026]=outside;for(uint i=1027;i<1032;i++)out[i]=0;}
      else{out[id*4]=sum.r/max(1u,n);out[id*4+1]=sum.g/max(1u,n);out[id*4+2]=sum.b/max(1u,n);out[id*4+3]=float(n);}
    }
    """
}
