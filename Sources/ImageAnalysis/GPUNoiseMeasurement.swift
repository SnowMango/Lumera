import ImageRendering
import Foundation
import Metal
import ImagingCore

/// Shared GPU noise/texture measurement for calibration and developer checks.
/// Encoded-sRGB planar residuals and the CPU contract's sixteen sampled Hann
/// periodograms. All image-sized work stays on Metal; only 39 scalars are read.
/// Per-call scratch is released after completion, so differing ROIs do not grow a cache.
final class GPUNoiseMeasurement {
    private let device:MTLDevice,queue:MTLCommandQueue
    private let pipelines:[MTLComputePipelineState]
    init(device:MTLDevice) throws {
        self.device=device
        guard let queue=device.makeCommandQueue() else {throw LabError.io("无法创建 GPU 噪点测量队列")}
        self.queue=queue
        let options=MTLCompileOptions();options.fastMathEnabled=false
        let library=try device.makeLibrary(source:Self.shader,options:options)
        pipelines=try ["noiseMoments","noisePlanes","noiseResiduals","noisePSD","noiseFinish"].map {
            guard let function=library.makeFunction(name:$0) else {throw LabError.io("缺少 GPU 噪点测量函数")}
            return try device.makeComputePipelineState(function:function)
        }
    }
    func measure(_ texture:MTLTexture,region:Region,kind:MeasurementKind,scale:Double=1) throws -> GPUFeatureStatistics {
        try Task.checkCancellation();try region.validate()
        guard scale.isFinite,(0.05...20).contains(scale) else {throw LabError.measurement("参考图像素换算比例应在 0.05–20 之间")}
        guard kind == .noise || kind == .texture else {throw LabError.measurement("GPU 噪点测量仅支持噪点和纹理")}
        guard abs(scale-1)<=1e-8 else {throw LabError.measurement("测量噪点或纹理前，两图须具有相同成像像素尺度；参考图像素换算比例必须为 1。修改此数值不会缩放照片。")}
        let x=Int(region.x*Double(texture.width)),y=Int(region.y*Double(texture.height))
        let w=min(texture.width-x,Int(region.width*Double(texture.width))),h=min(texture.height-y,Int(region.height*Double(texture.height)))
        guard w>=16,h>=16 else {throw LabError.measurement("测量选区至少需要 16 × 16 像素，请扩大选区")}
        let tiles=(w*h+255)/256
        // partials contain 3 channel moments in each of three directions and a clip flag.
        guard let partials=device.makeBuffer(length:tiles*10*4,options:.storageModePrivate),
              let planes=device.makeBuffer(length:10*4,options:.storageModePrivate),
              let powers=device.makeBuffer(length:16*33*4,options:.storageModePrivate),
              let output=device.makeBuffer(length:39*4,options:.storageModeShared),
              let command=queue.makeCommandBuffer() else {throw LabError.io("GPU 噪点统计内存不足")}
        var geometry=[UInt32(x),UInt32(y),UInt32(w),UInt32(h),UInt32(tiles)]
        for (index,count) in [tiles,10,tiles,16*33,39].enumerated() {
            try Task.checkCancellation()
            guard let encoder=command.makeComputeCommandEncoder() else {throw LabError.io("无法创建 GPU 噪点测量任务")}
            let pipeline=pipelines[index]
            encoder.label="CCDLab noise measurement phase \(index)"
            encoder.setComputePipelineState(pipeline);encoder.setTexture(texture,index:0)
            encoder.setBuffer(partials,offset:0,index:0);encoder.setBuffer(planes,offset:0,index:1)
            encoder.setBuffer(powers,offset:0,index:2);encoder.setBuffer(output,offset:0,index:3)
            encoder.setBytes(&geometry,length:geometry.count*4,index:4)
            encoder.dispatchThreads(MTLSize(width:count,height:1,depth:1),threadsPerThreadgroup:MTLSize(width:min(32,pipeline.maxTotalThreadsPerThreadgroup),height:1,depth:1))
            encoder.endEncoding()
        }
        try Task.checkCancellation();command.commit();command.waitUntilCompleted();try Task.checkCancellation()
        guard command.status == .completed else {throw LabError.io("GPU 噪点测量失败：\(command.error?.localizedDescription ?? "未知错误")")}
        let pointer=output.contents().bindMemory(to:Float.self,capacity:39)
        let values=(0..<39).map{Double(pointer[$0])}
        guard values.allSatisfy(\.isFinite) else {throw LabError.measurement("GPU 噪点统计无效")}
        let sigma=sqrt(max(0,values[1])),cb=sqrt(max(0,values[2])),cr=sqrt(max(0,values[3]))
        var warnings=[String]()
        if w<64 || h<64 {warnings.append("选区不足 64 × 64 像素，频谱使用了重复延展，可靠性较低；请扩大均匀区域或纹理选区。")}
        warnings.append(kind == .noise ? "单张照片估计的噪点仍可能包含纹理；请拍摄多组相同曝光的均匀平面，检查测量是否稳定。" : "纹理比较需要对应的相同图案和像素尺度；图案不同会被误当成处理效果差异。")
        if values[5]>0 {warnings.append("选区含接近纯黑或纯白的像素，可能截断噪点起伏并影响频谱；请检查欠曝、过曝或裁切。")}
        return GPUFeatureStatistics(metrics:["mean":values[0],"sigmaY":sigma,"sigmaCb":cb,"sigmaCr":cr,"rms":sigma,"chromaCorrelation":values[4]/max(1e-15,cb*cr)],curves:["psd":Array(values[6..<39]),"frequency":(0...32).map{Double($0)/64/scale}],warnings:warnings,width:w,height:h,readbackBytes:39*4,submissions:1,gpuSeconds:max(0,command.gpuEndTime-command.gpuStartTime))
    }
    private static let shader="""
    #include <metal_stdlib>
    using namespace metal;
    // This algebra avoids spurious chroma for exactly grey data. Subtracting an
    // anchor before fitting also protects low-amplitude noise on a bright field.
    float3 noiseChannels(float3 rgb) {
      float rg=rgb.r-rgb.g,bg=rgb.b-rgb.g;
      return float3(rgb.g+0.2126f*rg+0.0722f*bg,
        (0.9278f*bg-0.2126f*rg)/1.8556f,(0.7874f*rg-0.0722f*bg)/1.5748f);
    }
    void noiseAdd(float value,thread float& sum,thread float& error) {
      float adjusted=value-error,next=sum+adjusted;error=(next-sum)-adjusted;sum=next;
    }
    float3 noiseValue(texture2d<float,access::read> image,constant uint* g,uint x,uint y) {
      return noiseChannels(image.read(uint2(x+g[0],y+g[1])).rgb-image.read(uint2(g[0],g[1])).rgb);
    }
    float3 noiseResidual(texture2d<float,access::read> image,constant uint* g,const device float* plane,uint x,uint y) {
      float3 v=noiseValue(image,g,x,y);float dx=float(x)-float(g[2]-1)*0.5f,dy=float(y)-float(g[3]-1)*0.5f;
      for(uint c=0;c<3;c++)v[c]=v[c]-plane[c]-plane[3+c]*dx-plane[6+c]*dy;
      return v;
    }
    kernel void noiseMoments(texture2d<float,access::read> image[[texture(0)]],device float* partials[[buffer(0)]],constant uint* g[[buffer(4)]],uint tile[[thread_position_in_grid]]) {
      if(tile>=g[4])return;float sums[10]={0},errors[10]={0};
      uint end=min((tile+1)*256,g[2]*g[3]);
      for(uint i=tile*256;i<end;i++) {
        uint x=i%g[2],y=i/g[2];float3 v=noiseValue(image,g,x,y);
        float dx=float(x)-float(g[2]-1)*0.5f,dy=float(y)-float(g[3]-1)*0.5f;
        for(uint c=0;c<3;c++) {noiseAdd(v[c],sums[c],errors[c]);noiseAdd(v[c]*dx,sums[c+3],errors[c+3]);noiseAdd(v[c]*dy,sums[c+6],errors[c+6]);}
        float luminance=noiseChannels(image.read(uint2(x+g[0],y+g[1])).rgb).x;
        sums[9]=max(sums[9],float(luminance<0.001f || luminance>0.999f));
      }
      for(uint j=0;j<10;j++)partials[tile*10+j]=sums[j];
    }
    kernel void noisePlanes(const device float* partials[[buffer(0)]],device float* plane[[buffer(1)]],constant uint* g[[buffer(4)]],uint j[[thread_position_in_grid]]) {
      if(j>=10)return;float sum=0,error=0;
      for(uint t=0;t<g[4];t++)noiseAdd(partials[t*10+j],sum,error);
      float n=float(g[2])*float(g[3]);float denominator=n;
      if(j>=3 && j<6)denominator=n*(float(g[2])*float(g[2])-1.0f)/12.0f;
      if(j>=6 && j<9)denominator=n*(float(g[3])*float(g[3])-1.0f)/12.0f;
      plane[j]=j==9 ? sum:sum/denominator;
    }
    kernel void noiseResiduals(texture2d<float,access::read> image[[texture(0)]],device float* partials[[buffer(0)]],const device float* plane[[buffer(1)]],constant uint* g[[buffer(4)]],uint tile[[thread_position_in_grid]]) {
      if(tile>=g[4])return;float sums[4]={0},errors[4]={0};uint end=min((tile+1)*256,g[2]*g[3]);
      for(uint i=tile*256;i<end;i++) {
        float3 v=noiseResidual(image,g,plane,i%g[2],i/g[2]);
        for(uint c=0;c<3;c++)noiseAdd(v[c]*v[c],sums[c],errors[c]);noiseAdd(v.y*v.z,sums[3],errors[3]);
      }
      for(uint j=0;j<4;j++)partials[tile*10+j]=sums[j];
    }
    kernel void noisePSD(texture2d<float,access::read> image[[texture(0)]],const device float* plane[[buffer(1)]],device float* powers[[buffer(2)]],constant uint* g[[buffer(4)]],uint id[[thread_position_in_grid]]) {
      if(id>=528)return;uint line=id/33,k=id%33,row=line%8;bool horizontal=line<8;
      float values[64];float avg=0,error=0;
      for(uint i=0;i<64;i++) {
        uint x=horizontal ? i%g[2]:min(g[2]-1,(row+1)*g[2]/9);
        uint y=horizontal ? min(g[3]-1,(row+1)*g[3]/9):i%g[3];
        values[i]=noiseResidual(image,g,plane,x,y).x;noiseAdd(values[i],avg,error);
      }
      avg/=64.0f;float re=0,im=0,reError=0,imError=0;
      for(uint i=0;i<64;i++) {
        float v=(values[i]-avg)*(0.5f-0.5f*cos(2.0f*M_PI_F*float(i)/63.0f));
        // Integer phase wrapping avoids large-angle float argument error.
        float angle=2.0f*M_PI_F*float((k*i)%64)/64.0f;
        noiseAdd(v*cos(angle),re,reError);noiseAdd(-v*sin(angle),im,imError);
      }
      powers[id]=(re*re+im*im)/65536.0f;
    }
    kernel void noiseFinish(texture2d<float,access::read> image[[texture(0)]],const device float* partials[[buffer(0)]],const device float* plane[[buffer(1)]],const device float* powers[[buffer(2)]],device float* output[[buffer(3)]],constant uint* g[[buffer(4)]],uint id[[thread_position_in_grid]]) {
      if(id>=39)return;
      if(id==0){output[id]=noiseChannels(image.read(uint2(g[0],g[1])).rgb).x+plane[0];return;}
      if(id==5){output[id]=plane[9];return;}
      float sum=0,error=0;
      if(id<5){for(uint t=0;t<g[4];t++)noiseAdd(partials[t*10+id-1],sum,error);sum/=float(g[2])*float(g[3]);}
      else {for(uint line=0;line<16;line++)noiseAdd(powers[line*33+id-6],sum,error);}
      output[id]=sum;
    }
    """
}
