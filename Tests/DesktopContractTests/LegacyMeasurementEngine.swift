@testable import ImageAnalysis
// Frozen pre-optimization implementation for independent numerical regression tests.
// Deliberately does not call MeasurementEngine helpers; update only for a deliberate
// measurement contract change, never to accommodate an optimization.
// Contract 4: continuous triangular ESF weights replace hard histogram bins.
// This reference integrates each tent separately (production scatters to two neighbours).
import Foundation
import ImagingCore
import ImageRendering
enum LegacyMeasurementEngine {
    static func linear(_ x:Double)->Double { x<=0.04045 ? x/12.92 : pow((x+0.055)/1.055,2.4) }
    static func mean(_ a:[Double])->Double { a.reduce(0,+)/Double(max(1,a.count)) }
    static func rms(_ a:[Double])->Double { sqrt(mean(a.map{$0*$0})) }
    static func detrend(_ a:[Double],_ w:Int,_ h:Int)->[Double] {
        let m=mean(a),cx=Double(w-1)/2,cy=Double(h-1)/2
        var sx=0.0,sy=0.0,xx=0.0,yy=0.0
        for y in 0..<h {for x in 0..<w {let dx=Double(x)-cx,dy=Double(y)-cy,v=a[y*w+x]-m;sx+=v*dx;sy+=v*dy;xx+=dx*dx;yy+=dy*dy}}
        sx/=max(xx,1);sy/=max(yy,1)
        return a.enumerated().map{ $0.element-m-sx*(Double($0.offset%w)-cx)-sy*(Double($0.offset/w)-cy) }
    }
    /// Pooled row/column Hann periodograms, explicit frequency bins 0...Nyquist.
    static func psd(_ a:[Double],_ w:Int,_ h:Int)->[Double] {
        let n=64
        var sum=[Double](repeating:0,count:n/2+1)
        for axis in 0..<2 { for row in 0..<8 {
            var line=[Double](repeating:0,count:n)
            for i in 0..<n {
                let x=axis==0 ? i%w : min(w-1,(row+1)*w/9)
                let y=axis==0 ? min(h-1,(row+1)*h/9) : i%h
                line[i]=a[y*w+x]
            }
            let avg=mean(line)
            for k in 0...n/2 {
                var re=0.0,im=0.0
                for i in 0..<n {let v=(line[i]-avg)*(0.5-0.5*cos(2*Double.pi*Double(i)/Double(n-1)));let angle=2*Double.pi*Double(k*i)/Double(n);re+=v*cos(angle);im-=v*sin(angle)}
                sum[k]+=(re*re+im*im)/Double(n*n*16)
            }
        }}
        return sum
    }
    public static func measure(_ image:ImageFrame,region:Region=Region(),kind:MeasurementKind,scale:Double=1) throws -> ImageAnalysis.Measurement {
        try Task.checkCancellation();try region.validate()
        guard scale.isFinite,(0.05...20).contains(scale) else {throw LabError.measurement("参考图像素换算比例应在 0.05–20 之间")}
        if (kind == .noise || kind == .texture) && abs(scale-1)>1e-8 {
            throw LabError.measurement("测量噪点或纹理前，两图须具有相同成像像素尺度；参考图像素换算比例必须为 1。修改此数值不会缩放照片。")
        }
        let x0=Int(region.x*Double(image.width)),y0=Int(region.y*Double(image.height))
        let w=min(image.width-x0,Int(region.width*Double(image.width))),h=min(image.height-y0,Int(region.height*Double(image.height)))
        guard w>=16,h>=16 else {throw LabError.measurement("测量选区至少需要 16 × 16 像素，请扩大选区")}
        var yValues=[Double](),linearValues=[Double](),cb=[Double](),cr=[Double]()
        for y in y0..<y0+h {for x in x0..<x0+w {
            let i=(y*image.width+x)*4,r=Double(image.pixels[i]),g=Double(image.pixels[i+1]),b=Double(image.pixels[i+2])
            let l=0.2126*r+0.7152*g+0.0722*b;yValues.append(l);linearValues.append(0.2126*linear(r)+0.7152*linear(g)+0.0722*linear(b));cb.append((b-l)/1.8556);cr.append((r-l)/1.5748)
        }}
        var result=ImageAnalysis.Measurement(kind:kind,metrics:["mean":mean(yValues)],curves:[:],warnings:[],roi:region,pixelWidth:w,pixelHeight:h,scale:scale)
        switch kind {
        case .noise,.texture:
            let residual=detrend(yValues,w,h),b=detrend(cb,w,h),r=detrend(cr,w,h)
            let sigma=rms(residual),bs=rms(b),rs=rms(r)
            result.metrics.merge(["sigmaY":sigma,"sigmaCb":bs,"sigmaCr":rs,"chromaCorrelation":zip(b,r).map(*).reduce(0,+)/Double(w*h)/max(1e-15,bs*rs),"rms":sigma]){_,v in v}
            result.curves["psd"]=psd(residual,w,h)
            result.curves["frequency"]=(0...32).map{Double($0)/64/scale}
            if w<64 || h<64 {result.warnings.append("选区不足 64 × 64 像素，频谱使用了重复延展，可靠性较低；请扩大均匀区域或纹理选区。")}
            result.warnings.append(kind == .noise ? "单张照片估计的噪点仍可能包含纹理；请拍摄多组相同曝光的均匀平面，检查测量是否稳定。" : "纹理比较需要对应的相同图案和像素尺度；图案不同会被误当成处理效果差异。")
            if yValues.contains(where:{$0<0.001 || $0>0.999}) {result.warnings.append("选区含接近纯黑或纯白的像素，可能截断噪点起伏并影响频谱；请检查欠曝、过曝或裁切。")}
        case .vignette:
            let n=32;var sums=[Double](repeating:0,count:n),counts=[Int](repeating:0,count:n)
            let cx=Double(w)/2,cy=Double(h)/2,diagonal=hypot(Double(w),Double(h))/2
            for y in 0..<h {for x in 0..<w {let r=hypot(Double(x)+0.5-cx,Double(y)+0.5-cy)/diagonal;let bin=min(n-1,Int(r*Double(n)));sums[bin]+=linearValues[y*w+x];counts[bin]+=1}}
            var radial=(0..<n).map{counts[$0]>0 ? sums[$0]/Double(counts[$0]):Double.nan}
            fillMissing(&radial)
            let center=mean(Array(radial.prefix(3)))
            guard center>1e-6 else {throw LabError.measurement("平场中心太暗，无法可靠比较暗角；请提高拍摄曝光并避免过曝")}
            radial=radial.map{$0/center};result.curves["radial"]=radial
            result.metrics["edgeEV"] = -log2(max(1e-8,radial.last!))
            result.warnings.append("暗角测量须使用均匀照明的全幅平面；此方法无法区分照明不均与镜头暗角。")
        case .glow:
            let sorted=linearValues.sorted(),background=sorted[sorted.count/4],peak=sorted.last!
            guard peak-background>0.05 else {throw LabError.measurement("亮源与背景的反差不足，请使用暗背景中的孤立亮源")}
            var cx=0.0,cy=0.0,weight=0.0
            for y in 0..<h {for x in 0..<w {let v=max(0,linearValues[y*w+x]-(background+0.9*(peak-background)));cx+=v*Double(x);cy+=v*Double(y);weight+=v}}
            cx/=max(weight,1e-12);cy/=max(weight,1e-12)
            let radius=Double(min(w,h))/2
            guard cx>=2,cy>=2,cx<Double(w-2),cy<Double(h-2) else {throw LabError.measurement("亮源太靠近选区边缘，请重新框选，使亮源居中并包含完整光晕")}
            let bins=min(512,max(32,Int(radius*2)))
            var sums=[Double](repeating:0,count:bins),counts=[Int](repeating:0,count:bins),energy=0.0,moment=0.0
            for y in 0..<h {for x in 0..<w {let distance=hypot(Double(x)-cx,Double(y)-cy);if distance>=radius{continue};let v=max(0,linearValues[y*w+x]-background);let bin=min(bins-1,Int(floor(distance/radius*Double(bins)+1e-9)));sums[bin]+=v;counts[bin]+=1;energy+=v;moment+=v*distance*distance}}
            guard energy>0 else {throw LabError.measurement("选区没有可测量的亮源扩散，请检查亮源和背景")}
            result.curves["radial"]=(0..<bins).map{sums[$0]/Double(max(1,counts[$0]))/max(peak-background,1e-9)}
            result.curves["energy"]=sums.map{$0/energy}
            var accumulated=0.0
            result.curves["encircled"]=sums.map{accumulated += $0;return accumulated/energy}
            result.curves["radiusPixels"]=(0..<bins).map{Double($0+1)*radius/Double(bins)*scale}
            result.curves["crossSection"]=(0..<w).map{(linearValues[min(h-1,Int(cy))*w+$0]-background)/max(peak-background,1e-9)}
            result.metrics["spread"]=sqrt(moment/energy)*scale
            result.metrics["peak"]=peak;result.metrics["energy"]=energy;result.metrics["background"]=background
            result.warnings.append("测得的扩散也包含光源自身大小、曝光截断和镜头效果；两图须使用大小、曝光和拍摄条件可比的孤立亮源。")
        case .edge:
            try measureEdge(yValues,w,h,scale,&result)
        }
        return result
    }
    private static func fillMissing(_ values:inout [Double]) {
        for i in values.indices where !values[i].isFinite {
            let left=(0..<i).reversed().first{values[$0].isFinite},right=((i+1)..<values.count).first{values[$0].isFinite}
            if let l=left,let r=right {values[i]=values[l]+(values[r]-values[l])*Double(i-l)/Double(r-l)}
            else {values[i]=left.map{values[$0]} ?? right.map{values[$0]} ?? 0}
        }
    }
    private static func measureEdge(_ pixels:[Double],_ width:Int,_ height:Int,_ scale:Double,_ result:inout ImageAnalysis.Measurement) throws {
        var dx=0.0,dy=0.0
        for y in 1..<height {for x in 1..<width {dx+=abs(pixels[y*width+x]-pixels[y*width+x-1]);dy+=abs(pixels[y*width+x]-pixels[(y-1)*width+x])}}
        let transpose=dy>dx,w=transpose ? height:width,h=transpose ? width:height
        let a=transpose ? (0..<h).flatMap{y in(0..<w).map{x in pixels[x*width+y]}}:pixels
        let sorted=a.sorted(),low=sorted[sorted.count/10],high=sorted[sorted.count*9/10],contrast=high-low
        guard contrast>0.05,w>=32,h>=32 else {throw LabError.measurement("边缘选区至少需要 32 × 32 像素，明暗灰阶差需大于 0.05（0–1 标度）；请扩大选区或选择更清晰的边缘")}
        var positions=[Double]()
        for y in 0..<h {var sum=0.0,weight=0.0;for x in 1..<w {let d=abs(a[y*w+x]-a[y*w+x-1]);sum+=d*(Double(x)-0.5);weight+=d};positions.append(sum/max(weight,1e-10))}
        let center=mean(positions),hy=Double(h-1)/2
        let denominator=(0..<h).map{pow(Double($0)-hy,2)}.reduce(0,+)
        let slope=(0..<h).map{(Double($0)-hy)*(positions[$0]-center)}.reduce(0,+)/max(denominator,1)
        guard abs(slope)>=0.015,abs(slope)<0.3,center>8,center<Double(w-8) else {throw LabError.measurement("请框选单一的直线边缘，相对水平或垂直倾斜约 1–15°，放在选区中央并在两侧留出平坦区域")}
        let rising=mean((0..<h).map{a[$0*w+w-1]})>mean((0..<h).map{a[$0*w]})
        var esf=[Double](repeating:.nan,count:128)
        for bin in 0..<128 {
            var sum=0.0,weightSum=0.0
            for y in 0..<h {for x in 0..<w {
                let distance=(Double(x)-center-slope*(Double(y)-hy))*(rising ? 1:-1)*scale
                let location=(distance+16)*4-0.5
                let weight=max(0,1-abs(location-Double(bin)))
                sum+=(a[y*w+x]-low)/contrast*weight;weightSum+=weight
            }}
            if weightSum>0 {esf[bin]=sum/weightSum}
        }
        fillMissing(&esf)
        var lsf=(1..<127).map{(esf[$0+1]-esf[$0-1])*0.5}
        for i in lsf.indices {lsf[i]*=0.54-0.46*cos(2*Double.pi*Double(i)/Double(lsf.count-1))}
        let dc=max(1e-12,abs(lsf.reduce(0,+)))
        let mtf=(0...64).map{k -> Double in
            let frequency=Double(k)/128;var re=0.0,im=0.0
            for i in lsf.indices {let angle=2*Double.pi*frequency*Double(i)/4;re+=lsf[i]*cos(angle);im-=lsf[i]*sin(angle)}
            return hypot(re,im)/dc
        }
        var mtf50=0.5
        for i in 1..<mtf.count where mtf[i]<=0.5 {mtf50=(Double(i-1)+(mtf[i-1]-0.5)/max(1e-12,mtf[i-1]-mtf[i]))/128;break}
        result.curves["edge"]=esf;result.curves["mtf"]=mtf
        result.metrics.merge(["mtf50":mtf50,"overshoot":max(0,(esf.max() ?? 1)-1),"undershoot":max(0,-(esf.min() ?? 0)),"slope":slope,"contrast":contrast]){_,v in v}
        result.warnings.append("斜边响应仅用于两图诊断比较，未做导数补偿，不等同于符合 ISO 的镜头分辨率测量。")
    }
}
