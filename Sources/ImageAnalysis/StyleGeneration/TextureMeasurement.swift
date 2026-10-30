import Foundation
import Metal
import ImagingCore

struct TextureMoments:Sendable {
    var varianceY:Double,varianceCb:Double,varianceCr:Double,bands:[Double]
    init(_ stats:GPUFeatureStatistics) throws {
        guard let y=stats.metrics["sigmaY"],let cb=stats.metrics["sigmaCb"],let cr=stats.metrics["sigmaCr"],let psd=stats.curves["psd"],psd.count==33 else {throw LabError.measurement("缺少噪声方差/频谱")}
        varianceY=y*y;varianceCb=cb*cb;varianceCr=cr*cr
        let raw=[psd[1...5].reduce(0,+),psd[6...15].reduce(0,+),psd[16...32].reduce(0,+)],sum=raw.reduce(0,+)
        bands=raw.map{$0/max(1e-20,sum)}
    }
    init(varianceY:Double,varianceCb:Double=0,varianceCr:Double=0,bands:[Double]) {self.varianceY=varianceY;self.varianceCb=varianceCb;self.varianceCr=varianceCr;self.bands=bands}
    func validate()throws {
        guard [varianceY,varianceCb,varianceCr].allSatisfy({$0.isFinite && $0>=0}),bands.count==3,bands.allSatisfy({$0.isFinite && $0>=0}),abs(bands.reduce(0,+)-1)<0.001 || varianceY<1e-12 else {throw LabError.measurement("纹理统计无效")}
    }
}
struct TemporalTexture:Sendable {
    var mean:Double,training:TextureMoments,validation:TextureMoments,lagSpread:Double,fixedVariance:Double
}
struct TextureCondition:Sendable {
    var exposureEV:Double,input:TemporalTexture,target:TemporalTexture,unit:TemporalTexture
}
/// Four repeat frames, six differences. No image-sized CPU readback. The first
/// pair trains; the disjoint last pair validates. Other lags test temporal dependence.
final class GPUTemporalTexture {
    private let device:MTLDevice,queue:MTLCommandQueue,pipeline:MTLComputePipelineState,measurement:GPUNoiseMeasurement
    init(device:MTLDevice)throws {
        self.device=device;guard let q=device.makeCommandQueue() else {throw LabError.noMetal};queue=q
        let library=try device.makeLibrary(source:"""
        #include <metal_stdlib>
        using namespace metal;
        kernel void difference(texture2d<float,access::read>a[[texture(0)]],texture2d<float,access::read>b[[texture(1)]],texture2d<float,access::write>o[[texture(2)]],uint2 p[[thread_position_in_grid]]) {
          if(p.x>=o.get_width()||p.y>=o.get_height())return;
          o.write(float4(0.5f+(a.read(p).rgb-b.read(p).rgb)*0.7071067811865475f,1),p);
        }
        """,options:nil)
        pipeline=try device.makeComputePipelineState(function:library.makeFunction(name:"difference")!);measurement=try GPUNoiseMeasurement(device:device)
    }
    func measure(_ frames:[MTLTexture])throws->TemporalTexture {
        guard frames.count==4,let first=frames.first,first.width>=256,first.height>=256,first.width<=512,first.height<=512,
              frames.allSatisfy({$0.width==first.width && $0.height==first.height && $0.pixelFormat == .rgba32Float}) else {throw LabError.measurement("重复测量需要四张同尺寸的 256–512 像素原生裁切")}
        let originals=try frames.map{try measurement.measure($0,region:.init(),kind:.noise)}
        let means=originals.map{$0.metrics["mean"]!}
        guard means.allSatisfy({$0>0.08 && $0<0.92}),means.max()!-means.min()!<0.002,
              !originals.contains(where:{$0.warnings.contains(where:{$0.contains("裁切")})}) else {throw LabError.measurement("重复帧曝光漂移或接近裁切，请锁定曝光并重拍")}
        let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba32Float,width:first.width,height:first.height,mipmapped:false);d.storageMode = .private;d.usage=[.shaderRead,.shaderWrite]
        guard let diff=device.makeTexture(descriptor:d) else {throw LabError.noMetal}
        var pairs=[TextureMoments]()
        for (a,b) in [(0,1),(2,3),(0,2),(0,3),(1,2),(1,3)] {
            try Task.checkCancellation()
            guard let cmd=queue.makeCommandBuffer(),let enc=cmd.makeComputeCommandEncoder() else {throw LabError.noMetal}
            enc.setComputePipelineState(pipeline);enc.setTexture(frames[a],index:0);enc.setTexture(frames[b],index:1);enc.setTexture(diff,index:2)
            enc.dispatchThreads(.init(width:first.width,height:first.height,depth:1),threadsPerThreadgroup:.init(width:16,height:16,depth:1));enc.endEncoding();cmd.commit();cmd.waitUntilCompleted()
            if let e=cmd.error {throw e};pairs.append(try .init(measurement.measure(diff,region:.init(),kind:.noise)))
        }
        let variances=pairs.map(\.varianceY),average=variances.reduce(0,+)/6
        let spread=(variances.max()!-variances.min()!)/max(1e-10,average)
        guard spread<0.2 else {throw LabError.measurement("重复帧间噪声不独立或不稳定，不能按新增方差估计；检查时序降噪、移动与重复文件")}
        let fixed=max(0,originals.map{pow($0.metrics["sigmaY"]!,2)}.reduce(0,+)/4-average)
        return .init(mean:means.reduce(0,+)/4,training:pairs[0],validation:pairs[1],lagSpread:spread,fixedVariance:fixed)
    }
}
