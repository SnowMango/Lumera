import Foundation
import ImagingCore

/// Independent scalar, Double-precision reference. Only the measurement uses production GPU kernels.
struct DetailReferenceSamples {
    var folder:URL,measurements:MeasurementBundle
    func cleanup(){try? FileManager.default.removeItem(at:folder)}
    static func make(side:Int=2048,fineGain:Double=1.18,softness:Double=0.45,printWidth:Double=0.8,highFrequency:Bool=true,allConditions:Bool=false) throws ->Self {
        func decode(_ v:Double)->Double {v<=0.04045 ? v/12.92:pow((v+0.055)/1.055,2.4)}
        func encode(_ v:Double)->Double {v<=0.0031308 ? v*12.92:1.055*pow(v,1/2.4)-0.055}
        let w=side,h=side,n=w*h
        var pixels=[Double](repeating:0.5,count:n)
        let layout=TargetLayout.composite
        for region in layout.regions where region.kind == .edge || region.kind == .detail {
            let r=region.rect,x0=Int(r.x*Double(w)),x1=Int((r.x+r.width)*Double(w)),y0=Int(r.y*Double(h)),y1=Int((r.y+r.height)*Double(h))
            for y in y0..<y1 {for x in x0..<x1 {
                if region.kind == .edge {let d=Double(x)-Double(x0+x1)/2-0.0875*(Double(y)-Double(y0+y1)/2);pixels[y*w+x]=0.2+0.4*(0.5+0.5*erf(d/(printWidth*sqrt(2))))}
                else {pixels[y*w+x]=0.5+0.12*sin(Double(x)*0.5)+0.07*sin(Double(y)*0.9)+(highFrequency ? 0.04*sin(Double(x)*1.9+Double(y)*1.3):0)}
            }}
        }
        func blur(_ input:[Double],_ sigma:Double)->[Double] {
            let radius=Int(ceil(sigma*3)),weights=(-radius...radius).map{exp(-0.5*pow(Double($0)/sigma,2))},sum=weights.reduce(0,+)
            var temporary=input,out=input
            for y in 0..<h {for x in 0..<w {var v=0.0;for k in -radius...radius {v+=input[y*w+min(w-1,max(0,x+k))]*weights[k+radius]};temporary[y*w+x]=v/sum}}
            for y in 0..<h {for x in 0..<w {var v=0.0;for k in -radius...radius {v+=temporary[min(h-1,max(0,y+k))*w+x]*weights[k+radius]};out[y*w+x]=v/sum}}
            return out
        }
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        do {
            let plan=try CaptureProtocol(input:.init(id:"a",isoLevels:[100,400,1600],baseExposureSeconds:0.01),target:.init(id:"b",isoLevels:[100,400,1600],baseExposureSeconds:0.01))
            let renderer=try MetalRenderer(cacheLimitBytes:128*1024*1024);defer{renderer.releaseCaches()}
            var frames=[FrameMeasurements]()
            for step in plan.steps where step.target == .composite && (allConditions || step.conditionIndex==0) {
              try autoreleasepool {
                // Genuine independent exposure/repeat pixels, never the same file relabelled.
                let exposed=pixels.map {v -> Double in
                    let scene=max(0,v+Double(step.repeatIndex-1)*0.0004+Double(step.conditionIndex)*0.00002)
                    return encode(decode(scene)*pow(2,step.exposureEV))
                }
                let canonical=try ImageCodec.normalizedMaterial(ImageFrame(width:w,height:h,pixels:exposed.flatMap{[Float($0),Float($0),Float($0),Float(1)]}))
                let source=stride(from:0,to:canonical.pixels.count,by:4).map{Double(canonical.pixels[$0])}
                let values:[Double]
                if step.role == .input {values=source}
                else {
                    let fine=blur(source,0.75*Double(w)/2048)
                    let detailed=zip(source,fine).map{$0+(fineGain-1)*($0-$1)}
                    let linear=detailed.map(decode),scattered=blur(linear,1.5*Double(w)/2048)
                    values=zip(linear,scattered).map{encode($0*(1-softness)+$1*softness)}
                }
                let image=try ImageFrame(width:w,height:h,pixels:values.flatMap{[Float($0),Float($0),Float($0),Float(1)]})
                let url=folder.appendingPathComponent(step.id+".png"),data=try ImageCodec.encodeReference(image)
                try data.write(to:url)
                let loaded=try ImageCodec.load(url),pose=ProjectiveTransform(coefficients:[Double(w),0,0,0,Double(h),0,0,0,1])
                func roi(_ id:String)->Region {let r=layout.regions.first{$0.id==id}!.rect;return Region(x:r.x+r.width*0.1,y:r.y+r.height*0.1,width:r.width*0.8,height:r.height*0.8)}
                let edge=try renderer.measureFeatureStatistics(loaded,region:roi("edge"),kind:.edge)
                let detail=try renderer.measureFeatureStatistics(loaded,region:roi("detail"),kind:.texture)
                let patches=try renderer.renderPatchStatistics(loaded,style:ResolvedStyle(profile:.standard),transform:pose,regions:layout.regions)
                var c=CaptureConditions();c.iso=step.expectedISO;c.exposureDurationSeconds=step.expectedExposureSeconds
                var metrics=edge.metrics;metrics["detailRMS"]=detail.metrics["rms"]
                var curves=edge.curves;curves["detailPSD"]=detail.curves["psd"]
                frames.append(.init(fileDigest:Digest.data(data),step:step,actualConditions:c,width:w,height:h,patches:patches,sourceURL:url,pose:pose,metrics:metrics,curves:curves))
              }
            }
            return .init(folder:folder,measurements:.init(frames:frames,resourceDigests:[:]))
        } catch {try? FileManager.default.removeItem(at:folder);throw error}
    }
}
