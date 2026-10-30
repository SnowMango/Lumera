import Foundation

/// Descriptive metadata only. These values never reapply capture exposure or white balance.
public struct CaptureConditions:Codable,Equatable,Sendable {
    public var iso:Double?
    public var exposureDurationSeconds:Double?
    public var exposureBiasEV:Double?
    public var whiteBalanceTemperatureKelvin:Double?
    /// CIE 1960 uv Duv; vendor/Apple tint sliders are not this unit.
    public var whiteBalanceTintDuv:Double?
    public init() {}
    public subscript(axis:ConditionAxis)->Double? {
        get {switch axis {
        case .iso:return iso
        case .exposureDurationSeconds:return exposureDurationSeconds
        case .exposureBiasEV:return exposureBiasEV
        case .whiteBalanceTemperatureKelvin:return whiteBalanceTemperatureKelvin
        case .whiteBalanceTintDuv:return whiteBalanceTintDuv
        }}
        set {switch axis {
        case .iso:iso=newValue
        case .exposureDurationSeconds:exposureDurationSeconds=newValue
        case .exposureBiasEV:exposureBiasEV=newValue
        case .whiteBalanceTemperatureKelvin:whiteBalanceTemperatureKelvin=newValue
        case .whiteBalanceTintDuv:whiteBalanceTintDuv=newValue
        }}
    }
    public func validate() throws {
        for axis in ConditionAxis.allCases {if let value=self[axis] {try axis.validate(value)}}
    }
    public func overriding(_ overrides:CaptureConditions)->CaptureConditions {
        var result=self
        for axis in ConditionAxis.allCases {if let value=overrides[axis] {result[axis]=value}}
        return result
    }
}
public enum ConditionAxis:String,Codable,CaseIterable,Sendable {
    case iso,exposureDurationSeconds,exposureBiasEV,whiteBalanceTemperatureKelvin,whiteBalanceTintDuv
    public var logarithmic:Bool {self == .iso || self == .exposureDurationSeconds}
    public var unit:String {switch self {
    case .iso:return "ISO"
    case .exposureDurationSeconds:return "s"
    case .exposureBiasEV:return "EV（拍摄曝光补偿）"
    case .whiteBalanceTemperatureKelvin:return "K"
    case .whiteBalanceTintDuv:return "Duv（CIE 1960 uv）"
    }}
    public func validate(_ value:Double) throws {
        guard value.isFinite,(!(logarithmic || self == .whiteBalanceTemperatureKelvin) || value>0) else {throw LabError.invalid("拍摄条件 \(unit) 必须为有效\(logarithmic || self == .whiteBalanceTemperatureKelvin ? "正":"")数值；未知请留空")}
    }
    func coordinate(_ x:Double)->Double {logarithmic ? log2(x):x}
}
