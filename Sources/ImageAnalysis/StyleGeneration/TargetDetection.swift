import Foundation
import Vision
import ImagingCore

public struct DetectedMarker:Sendable {public var id:String,center:TargetPoint}
public struct DetectedTarget:Codable,Equatable,Sendable {public var layoutVersion:String,transform:ProjectiveTransform,width:Int,height:Int}
public enum TargetDetection {
    /// Vision decodes marker payloads; only geometry is transformed, never the measured pixels.
    public static func detect(image:ImageFrame,layout:TargetLayout = .composite) throws -> DetectedTarget {
        try Task.checkCancellation();try image.validateStorage()
        let request=VNDetectBarcodesRequest();request.symbologies=[.qr]
        try VNImageRequestHandler(cgImage:ImageCodec.cgImage(image),options:[:]).perform([request])
        try Task.checkCancellation()
        let markers=(request.results ?? []).compactMap {observation -> DetectedMarker? in
            guard let text=observation.payloadStringValue,text.hasPrefix("LM") else{return nil}
            let points=[observation.topLeft,observation.topRight,observation.bottomRight,observation.bottomLeft].map{TargetPoint(x:$0.x*Double(image.width),y:(1-$0.y)*Double(image.height))}
            let unit=[TargetPoint(x:0,y:0),.init(x:1,y:0),.init(x:1,y:1),.init(x:0,y:1)]
            guard let square=try? ProjectiveTransform.fit(from:unit,to:points) else{return nil}
            return .init(id:text,center:square.project(.init(x:0.5,y:0.5)))
        }
        guard markers.count==4,Set(markers.map(\.id))==Set(layout.markers.map(\.id)) else {throw LabError.measurement("需要完整的四个 LM1 定位码")}
        let codeTransform=try ProjectiveTransform.fit(from:layout.markers.map(\.codeCenter),to:layout.markers.map{m in markers.first{$0.id==m.id}!.center})
        let refined=try layout.markers.map {m -> DetectedMarker in
            let center=codeTransform.project(m.center)
            let nearby=codeTransform.project(.init(x:m.center.x+4/210,y:m.center.y))
            let radius=center.distance(to:nearby)
            guard center.x.isFinite,center.y.isFinite,(0..<Double(image.width)).contains(center.x),(0..<Double(image.height)).contains(center.y),radius.isFinite,radius>=8,radius<=100 else {throw LabError.measurement("定位点尺度不足或透视异常")}
            // Local centroid refinement touches <0.1% of a typical source. This is geometry only;
            // production color/detail/texture statistics remain GPU reductions without resampling.
            let x0=max(0,Int(center.x-radius)),x1=min(image.width-1,Int(center.x+radius))
            let y0=max(0,Int(center.y-radius)),y1=min(image.height-1,Int(center.y+radius))
            guard x1>x0,y1>y0 else {throw LabError.measurement("定位点被裁切")}
            var mass=0.0,sx=0.0,sy=0.0
            for y in y0...y1 {for x in x0...x1 {
                let i=(y*image.width+x)*4,luma=Double(image.pixels[i]*0.2126+image.pixels[i+1]*0.7152+image.pixels[i+2]*0.0722)
                let weight=max(0,1-luma*2)
                if hypot(Double(x)+0.5-center.x,Double(y)+0.5-center.y)<radius {mass+=weight;sx+=(Double(x)+0.5)*weight;sy+=(Double(y)+0.5)*weight}
            }}
            guard mass>radius*radius*0.2,mass<radius*radius*1.8 else {throw LabError.measurement("独立定位点缺失或被反光/污损遮挡")}
            let centroid=TargetPoint(x:sx/mass,y:sy/mass)
            // Check the independent printed disk against the locally projected 2 mm radius.
            // A centroid alone silently accepts half-disks caused by glare or occlusion.
            let px=codeTransform.project(.init(x:m.center.x+2/210,y:m.center.y))
            let py=codeTransform.project(.init(x:m.center.x,y:m.center.y+2/297))
            let ax=px.x-center.x,ay=px.y-center.y,bx=py.x-center.x,by=py.y-center.y
            let determinant=ax*by-ay*bx,expectedMass=Double.pi*abs(determinant)
            guard expectedMass.isFinite,expectedMass>1,(0.80...1.20).contains(mass/expectedMass) else {throw LabError.measurement("定位圆点面积异常，检查局部遮挡或反光")}
            var core=0.0,coreDark=0.0,ring=0.0,ringDark=0.0
            for y in y0...y1 {for x in x0...x1 {
                let dx=Double(x)+0.5-centroid.x,dy=Double(y)+0.5-centroid.y
                let r=hypot((by*dx-bx*dy)/determinant,(-ay*dx+ax*dy)/determinant)
                let i=(y*image.width+x)*4,luma=Double(image.pixels[i]*0.2126+image.pixels[i+1]*0.7152+image.pixels[i+2]*0.0722)
                if r<0.75 {core+=1;if luma<0.5 {coreDark+=1}}
                if r>1.15 && r<1.7 {ring+=1;if luma<0.5 {ringDark+=1}}
            }}
            guard core>0,ring>0,coreDark/core>=0.98,ringDark/ring<=0.01 else {throw LabError.measurement("定位圆点轮廓不完整，检查污损、反光或失焦")}
            return .init(id:m.id,center:centroid)
        }
        return try resolve(markers:refined,layout:layout,width:image.width,height:image.height)
    }
    static func resolve(markers:[DetectedMarker],layout:TargetLayout,width:Int,height:Int) throws -> DetectedTarget {
        guard width>=1200,height>=1200,markers.count==4,Set(markers.map(\.id))==Set(layout.markers.map(\.id)),
              markers.allSatisfy({$0.center.x.isFinite && $0.center.y.isFinite && (0..<Double(width)).contains($0.center.x) && (0..<Double(height)).contains($0.center.y)}) else {throw LabError.measurement("综合板需至少 1200 像素短边、四个 LM1 定位码完整且不重复；请检查裁切、图号、对焦和反光")}
        let ordered=layout.markers.map{m in markers.first{$0.id==m.id}!.center}
        let h=try ProjectiveTransform.fit(from:layout.markers.map(\.center),to:ordered)
        for region in layout.regions {for p in region.rect.corners {
            let q=h.project(p)
            guard q.x.isFinite,q.y.isFinite,(2..<Double(width-2)).contains(q.x),(2..<Double(height-2)).contains(q.y) else {throw LabError.measurement("测量区域被裁切或透视退化，请正对目标板重拍")}
        }}
        let lengths=(0..<4).map{ordered[$0].distance(to:ordered[($0+1)%4])}
        guard let low=lengths.min(),let high=lengths.max(),low>=500,high/low<=3 else {throw LabError.measurement("目标板太小或倾斜过大，请靠近并正对目标板")}
        return .init(layoutVersion:layout.version,transform:h,width:width,height:height)
    }
}
