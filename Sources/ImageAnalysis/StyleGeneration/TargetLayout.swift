import Foundation
import ImagingCore

public struct TargetPoint:Codable,Equatable,Sendable {
    public var x:Double,y:Double
    public init(x:Double,y:Double) {self.x=x;self.y=y}
    public func distance(to p:TargetPoint)->Double {hypot(x-p.x,y-p.y)}
}
public struct TargetRect:Codable,Equatable,Sendable {
    public var x:Double,y:Double,width:Double,height:Double
    public var corners:[TargetPoint] {[.init(x:x,y:y),.init(x:x+width,y:y),.init(x:x+width,y:y+height),.init(x:x,y:y+height)]}
}
public enum TargetRegionKind:String,Codable,Sendable {case gray,color,edge,detail,flat,light}
public struct TargetRegion:Codable,Equatable,Sendable {
    public var id:String,kind:TargetRegionKind,rect:TargetRect
    /// Printed values are drawing instructions, never reflectance truth.
    public var printedRGB:[Double]
}
public struct TargetMarker:Codable,Equatable,Sendable {public var id:String,center:TargetPoint,codeCenter:TargetPoint}
public struct TargetLayout:Codable,Equatable,Sendable {
    public var version:String,target:CaptureTarget,markers:[TargetMarker],regions:[TargetRegion]
    public static let composite:TargetLayout = {
        func rectangle(_ x:Double,_ y:Double,_ w:Double,_ h:Double)->TargetRect {.init(x:x/210,y:y/297,width:w/210,height:h/297)}
        let points=[(24.0,42.0),(186.0,42.0),(186.0,255.0),(24.0,255.0)]
        let markers=points.enumerated().map{TargetMarker(id:"LM1C\($0.offset)",center:.init(x:($0.element.0<100 ? $0.element.0+20:$0.element.0-20)/210,y:$0.element.1/297),codeCenter:.init(x:$0.element.0/210,y:$0.element.1/297))}
        var regions=[TargetRegion]()
        for i in 0..<12 {let v=0.05+0.9*Double(i)/11;regions.append(.init(id:"gray-\(i)",kind:.gray,rect:rectangle(48+Double(i%6)*20,67+Double(i/6)*18,12,10),printedRGB:[v,v,v]))}
        let colors:[[Double]]=[[0.7,0.2,0.2],[0.2,0.65,0.25],[0.2,0.25,0.7],[0.75,0.65,0.2],[0.65,0.2,0.65],[0.2,0.65,0.65],[0.6,0.42,0.3],[0.85,0.65,0.5],[0.35,0.45,0.2],[0.25,0.45,0.65],[0.6,0.35,0.5],[0.65,0.5,0.2],[0.45,0.2,0.2],[0.2,0.45,0.25],[0.2,0.25,0.45],[0.45,0.4,0.2],[0.4,0.2,0.45],[0.2,0.45,0.45]]
        for i in 0..<colors.count {regions.append(.init(id:"color-\(i)",kind:.color,rect:rectangle(48+Double(i%6)*20,112+Double(i/6)*18,12,10),printedRGB:colors[i]))}
        regions.append(.init(id:"edge",kind:.edge,rect:rectangle(46,180,50,50),printedRGB:[]))
        regions.append(.init(id:"detail",kind:.detail,rect:rectangle(110,180,50,50),printedRGB:[]))
        return .init(version:"LM1",target:.composite,markers:markers,regions:regions)
    }()
}
public struct ProjectiveTransform:Codable,Equatable,Sendable {
    public var coefficients:[Double]
    public init(coefficients:[Double]) {self.coefficients=coefficients}
    public func project(_ p:TargetPoint)->TargetPoint {
        guard coefficients.count==9 else{return .init(x:.nan,y:.nan)}
        let h=coefficients,w=h[6]*p.x+h[7]*p.y+h[8]
        return .init(x:(h[0]*p.x+h[1]*p.y+h[2])/w,y:(h[3]*p.x+h[4]*p.y+h[5])/w)
    }
    public func inverted() throws -> ProjectiveTransform {
        guard coefficients.count==9,coefficients.allSatisfy(\.isFinite) else {throw LabError.measurement("定位变换无效")}
        let a=coefficients
        let c=[a[4]*a[8]-a[5]*a[7],a[2]*a[7]-a[1]*a[8],a[1]*a[5]-a[2]*a[4],a[5]*a[6]-a[3]*a[8],a[0]*a[8]-a[2]*a[6],a[2]*a[3]-a[0]*a[5],a[3]*a[7]-a[4]*a[6],a[1]*a[6]-a[0]*a[7],a[0]*a[4]-a[1]*a[3]]
        let det=a[0]*c[0]+a[1]*c[3]+a[2]*c[6]
        guard det.isFinite,abs(det)>1e-10 else {throw LabError.measurement("定位点退化，无法确定目标平面")}
        return .init(coefficients:c.map{$0/det})
    }
    static func fit(from:[TargetPoint],to:[TargetPoint]) throws -> ProjectiveTransform {
        guard from.count==4,to.count==4 else {throw LabError.measurement("需要四个定位点")}
        var rows=[[Double]]()
        for (a,b) in zip(from,to) {
            rows.append([a.x,a.y,1,0,0,0,-b.x*a.x,-b.x*a.y,b.x])
            rows.append([0,0,0,a.x,a.y,1,-b.y*a.x,-b.y*a.y,b.y])
        }
        for col in 0..<8 {
            let pivot=(col..<8).max{abs(rows[$0][col])<abs(rows[$1][col])}!
            guard abs(rows[pivot][col])>1e-10 else {throw LabError.measurement("定位点重叠或共线")}
            rows.swapAt(col,pivot);let divisor=rows[col][col]
            for j in col...8 {rows[col][j]/=divisor}
            for i in 0..<8 where i != col {let factor=rows[i][col];for j in col...8 {rows[i][j]-=factor*rows[col][j]}}
        }
        let h=ProjectiveTransform(coefficients:rows.map{$0[8]}+[1]);_=try h.inverted();return h
    }
}
