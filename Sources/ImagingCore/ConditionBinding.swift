import Foundation

public enum ResponseOperation:String,Codable,CaseIterable,Sendable {case replace,multiply,add}
public enum ResponseTarget:String,Codable,CaseIterable,Sendable {
    case noiseGain="noise.gain",noiseChromaRatio="noise.chromaRatio"
    case grainAmount="grain.amount",grainSize="grain.size",grainRoughness="grain.roughness",grainChroma="grain.chroma"
    case softeningAmount="softening.amount",softeningSigma="softening.sigma"
    case fineGain="detail.fineGain",midGain="detail.midGain",sharpenAmount="detail.sharpenAmount"
    case glowAmount="glow.amount",glowThreshold="glow.threshold",halationAmount="halation.amount",halationThreshold="halation.threshold"
    case vignetteAmount="vignette.amountEV"
    public var descriptor:ParameterDescriptor? {ParameterDescriptor.all.first{$0.id==rawValue}}
    public var allowedOperations:[ResponseOperation] {self == .noiseGain ? [.multiply]:ResponseOperation.allCases}
    public var unit:String {self == .noiseGain ? "倍率":(descriptor?.unit ?? "normalized")}
    public var title:String {self == .noiseGain ? "数码噪点整体倍率":(descriptor?.title ?? rawValue)}
    /// Legal editing range for this response, given the current base parameters.
    public func responseRange(operation:ResponseOperation,parameters:StyleParameters)->ClosedRange<Double> {
        if self == .noiseGain {
            let base=parameters.noise.gain
            guard base>0 else{return 0...8}
            let peak=parameters.noise.curve.outputRange.upperBound*base
            var upper=min(8/base,peak>0 ? 0.1/peak:8/base)
            if base*upper>8 || peak*upper>0.1 {upper=upper.nextDown}
            return 0...upper
        }
        let d=descriptor!,base=parameters[keyPath:d.keyPath]
        switch operation {
        case .replace:return d.range
        case .add:return (d.range.lowerBound-base)...(d.range.upperBound-base)
        case .multiply:
            guard base != 0 else{return 0...8}
            let a=d.range.lowerBound/base,b=d.range.upperBound/base
            var lower=min(a,b),upper=max(a,b)
            if !(d.range.contains(base*lower)){lower=lower.nextUp}
            if !(d.range.contains(base*upper)){upper=upper.nextDown}
            return lower...upper
        }
    }
    func apply(_ value:Double,operation:ResponseOperation,to p:inout StyleParameters) throws {
        guard allowedOperations.contains(operation),value.isFinite else {throw LabError.invalid("\(rawValue) 不支持此响应操作或数值")}
        if self == .noiseGain {
            guard responseRange(operation:operation,parameters:p).contains(value) else {throw LabError.invalid("噪点整体倍率必须为 0–8")}
            p.noise.gain *= value
        } else {
            let d=descriptor!,base=p[keyPath:d.keyPath]
            let result:Double
            switch operation {case .replace:result=value;case .multiply:result=base*value;case .add:result=base+value}
            guard result.isFinite,d.range.contains(result) else {throw LabError.invalid("条件响应使 \(title) 超出 \(d.range)")}
            p[keyPath:d.keyPath]=result
        }
    }
}
public struct ConditionBinding:Codable,Equatable,Sendable {
    public var target:ResponseTarget,axis:ConditionAxis,operation:ResponseOperation,curve:ResponseCurve
    public init(target:ResponseTarget,axis:ConditionAxis,operation:ResponseOperation,curve:ResponseCurve) {
        self.target=target;self.axis=axis;self.operation=operation;self.curve=curve
    }
}
