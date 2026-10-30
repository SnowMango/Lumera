import Foundation

public struct ResponseKnot:Codable,Equatable,Sendable {
    public var x:Double,y:Double
    public init(x:Double,y:Double){self.x=x;self.y=y}
}
public enum ImageResponseKind:Sendable {case tone,noise,grain}
public enum CurveInterpolation:String,Codable,CaseIterable,Sendable {case linear,smooth}
public enum CurveFamily:String,Codable,CaseIterable,Sendable {
    case constant,linear,power,sigmoid,threshold,bell
    public var title:String {switch self {
    case .constant:return "恒定";case .linear:return "线性";case .power:return "幂函数"
    case .sigmoid:return "S形";case .threshold:return "平滑阈值";case .bell:return "钟形"
    }}
    public var code:Float {Float(Self.allCases.firstIndex(of:self)!+1)}
}
/// Analytic function in normalized axis coordinates. ISO/duration use log2 before normalization.
public struct CurveFunction:Codable,Equatable,Sendable {
    public var family:CurveFamily
    public var xLower=0.0,xUpper=1.0
    public var start:Double,end:Double
    public var exponent=2.0,center=0.5,width=0.25
    public init(family:CurveFamily,start:Double=0,end:Double=1) {self.family=family;self.start=start;self.end=end}
    public func value(normalized input:Double)->Double {
        let t=min(1,max(0,input)),v:Double
        switch family {
        case .constant:v=0
        case .linear:v=t
        case .power:v=pow(t,exponent)
        case .sigmoid:
            func logistic(_ x:Double)->Double {1/(1+exp(-exponent*4*(x-center)))}
            v=(logistic(t)-logistic(0))/(logistic(1)-logistic(0))
        case .threshold:
            let a=min(1,max(0,(t-center)/width+0.5));v=a*a*(3-2*a)
        case .bell:v=exp(-0.5*pow((t-center)/width,2))
        }
        let result=start*(1-v)+end*v
        return min(max(start,end),max(min(start,end),result))
    }
    public func validate() throws {
        guard [xLower,xUpper,start,end,exponent,center,width].allSatisfy({$0.isFinite}),xUpper>xLower,
              (0.25...8).contains(exponent),(0...1).contains(center),(0.05...1).contains(width) else {
            throw LabError.invalid("曲线函数范围无效：指数0.25–8，中心0–1，宽度0.05–1，横轴终点大于起点")
        }
    }
}
public enum CurveShape:Codable,Equatable,Sendable {
    case function(CurveFunction)
    case points([ResponseKnot],interpolation:CurveInterpolation)
}
/// The sole persisted curve definition. Functions and custom points are mutually exclusive.
public struct ResponseCurve:Codable,Equatable,Sendable {
    public var shape:CurveShape
    public init(function:CurveFunction){shape = .function(function)}
    public init(knots:[ResponseKnot],interpolation:CurveInterpolation = .linear){shape = .points(knots,interpolation:interpolation)}
    public var function:CurveFunction? {if case .function(let f)=shape{return f};return nil}
    public var interpolation:CurveInterpolation {if case .points(_,let mode)=shape{return mode};return .smooth}
    /// Control samples for validation and explicit conversion only; analytic functions are never baked for rendering.
    public var knots:[ResponseKnot] {
        get {if case .points(let k,_)=shape{return k};let f=function!;return (0..<32).map {i in let t=Double(i)/31;return .init(x:f.xLower+(f.xUpper-f.xLower)*t,y:f.value(normalized:t))}}
        set {shape = .points(newValue,interpolation:interpolation)}
    }
    public var outputRange:ClosedRange<Double> {
        if let f=function {return min(f.start,f.family == .constant ? f.start:f.end)...max(f.start,f.family == .constant ? f.start:f.end)}
        let ys=knots.map(\.y);return (ys.min() ?? 0)...(ys.max() ?? 0)
    }
    public func validate(kind:ImageResponseKind) throws {
        let upper=kind == .noise ? 0.1:1.0
        if let f=function {
            try f.validate()
            guard f.xLower==0,f.xUpper==1,outputRange.lowerBound>=0,outputRange.upperBound<=upper,
                  kind != .tone || (f.family != .bell && (f.family == .constant || f.start<=f.end)) else {throw LabError.invalid("此函数不适用于当前亮度响应或输出范围")}
        } else {
            let k=knots
            guard (2...32).contains(k.count),k.first?.x==0,k.last?.x==1,
                  k.allSatisfy({$0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...upper).contains($0.y)}),
                  zip(k,k.dropFirst()).allSatisfy({Float($1.x)-Float($0.x)>=1.0/1024}),
                  kind != .tone || zip(k,k.dropFirst()).allSatisfy({$0.y<=$1.y}) else {throw LabError.invalid("亮度节点需2–32个，横轴0–1、间距至少1/1024，输出在合法范围且色调单调")}
        }
    }
    public func validate(axis:ConditionAxis) throws {
        if let f=function {try f.validate()}
        let k=function.map{[ResponseKnot(x:$0.xLower,y:$0.start),ResponseKnot(x:$0.xUpper,y:$0.end)]} ?? knots
        guard (2...32).contains(k.count),k.allSatisfy({$0.x.isFinite && $0.y.isFinite}) else {throw LabError.invalid("条件曲线需要有限数值及2–32节点")}
        for p in k {try axis.validate(p.x)}
        for (a,b) in zip(k,k.dropFirst()) {
            let interval=axis.coordinate(b.x)-axis.coordinate(a.x)
            guard interval.isFinite,interval>0 else {throw LabError.invalid("条件曲线横轴需严格递增且间距可计算")}
        }
    }
    public func value(at x:Double)->Double {sample(at:x,coordinate:{$0})}
    public func value(at x:Double,axis:ConditionAxis) throws -> Double {try validate(axis:axis);try axis.validate(x);return sampleValidated(at:x,axis:axis)}
    func sampleValidated(at x:Double,axis:ConditionAxis)->Double {sample(at:x,coordinate:axis.coordinate)}
    private func sample(at x:Double,coordinate:(Double)->Double)->Double {
        guard x.isFinite else{return .nan}
        if let f=function {return f.value(normalized:(coordinate(x)-coordinate(f.xLower))/(coordinate(f.xUpper)-coordinate(f.xLower)))}
        let k=knots.map{ResponseKnot(x:coordinate($0.x),y:$0.y)},v=coordinate(x)
        guard k.count>=2 else{return k.first?.y ?? 0}
        if v<=k[0].x{return k[0].y};if v>=k.last!.x{return k.last!.y}
        let i=(1..<k.count).first{k[$0].x>=v}!-1,a=k[i],b=k[i+1],h=b.x-a.x,t=(v-a.x)/h
        if interpolation == .linear {return min(max(a.y,b.y),max(min(a.y,b.y),(1-t)*a.y+t*b.y))}
        let m=Self.tangents(k),t2=t*t,t3=t2*t
        let y=(2*t3-3*t2+1)*a.y+(t3-2*t2+t)*h*m[i]+(-2*t3+3*t2)*b.y+(t3-t2)*h*m[i+1]
        return min(max(a.y,b.y),max(min(a.y,b.y),y))
    }
    public static func tangents(_ k:[ResponseKnot])->[Double] {
        guard k.count>=2 else{return k.map{_ in 0}}
        let h=zip(k,k.dropFirst()).map{$1.x-$0.x},d=zip(k,k.dropFirst()).map{($1.y-$0.y)/($1.x-$0.x)}
        var result=[d[0]]
        for i in 1..<(k.count-1) {
            let a=d[i-1],b=d[i],w1=2*h[i]+h[i-1],w2=h[i]+2*h[i-1]
            result.append(a==0 || b==0 || (a>0) != (b>0) ? 0:(w1+w2)/(w1/a+w2/b))
        }
        return result+[d.last!]
    }
    public func convertedToPoints(axis:ConditionAxis?=nil)->ResponseCurve {
        guard let f=function else{return self}
        let a=axis?.coordinate(f.xLower) ?? f.xLower,b=axis?.coordinate(f.xUpper) ?? f.xUpper
        let k=(0..<32).map {i -> ResponseKnot in
            let t=Double(i)/31,v=a+(b-a)*t,x=axis?.logarithmic == true ? pow(2,v):v
            return .init(x:i==0 ? f.xLower:i==31 ? f.xUpper:x,y:f.value(normalized:t))
        }
        return .init(knots:k,interpolation:.smooth)
    }
    public static var identity:Self {.init(function:.init(family:.linear))}
    public static var grainDefault:Self {.init(function:.init(family:.bell))}

}
public enum TemporalMode:String,Codable,CaseIterable,Sendable {
    case fixed,evolving
    public func seed(_ seed:UInt32,frameIndex:UInt32)->UInt32 {
        self == .fixed ? seed:seed ^ (frameIndex &* 0x9e3779b9)
    }
}
public struct TemporalPolicy:Codable,Equatable,Sendable {
    public var noise:TemporalMode = .fixed
    public var grain:TemporalMode = .evolving
    public init() {}
}
