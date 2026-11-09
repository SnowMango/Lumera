import Foundation

/// Each namespace has independent meaning; source ISO never implies target ISO.
public enum ObservationAxis: Codable, Equatable, Sendable {
    case source(ConditionAxis)
    case target(ConditionAxis)
    case feature(String)
    public var logarithmic: Bool {
        switch self { case .source(let a), .target(let a): return a.logarithmic; case .feature: return false }
    }
    /// 将原始单位的观测值或节点位置转换成插值坐标。ISO 和曝光时长取 log₂。
    public func coordinate(_ value: Double) -> Double { logarithmic ? log2(value) : value }
    public func validate(_ value: Double) throws {
        switch self {
        case .source(let a), .target(let a): try a.validate(value)
        case .feature(let id): guard !id.isEmpty, value.isFinite else { throw LabError.invalid("Invalid feature axis") }
        }
    }
}
/// 规定有值但超出节点范围时如何处理；缺测另按 `MissingObservationPolicy` 处理。
public enum ResponseBoundaryPolicy: String, Codable, Sendable { case clamp, reject }
public enum MissingObservationPolicy: Codable, Equatable, Sendable {
    case reject
    case constant(ControlValue)
    /// 使用最近有效观测对应的历史控制，最大年龄以秒计。
    case hold(maxAgeSeconds: Double)
}
public struct ResponseNode: Codable, Equatable, Sendable {
    /// 以轴的原始单位声明节点位置，求值时再转换为插值坐标。
    public var position: Double
    public var value: ControlValue
    public init(_ position: Double, _ value: ControlValue) { self.position = position; self.value = value }
}
/// 支持常量、一维线性插值或二维双线性插值。
public enum ResponseExpression: Codable, Equatable, Sendable {
    case constant(ControlValue)
    case singleAxis(axis: ObservationAxis, nodes: [ResponseNode], boundary: ResponseBoundaryPolicy)
    /// x varies fastest: values[yIndex * x.count + xIndex].
    case twoAxisGrid(xAxis: ObservationAxis, yAxis: ObservationAxis, x: [Double], y: [Double], values: [ControlValue], boundary: ResponseBoundaryPolicy)
    public var axes: [ObservationAxis] {
        switch self { case .constant: return []; case .singleAxis(let a, _, _): return [a]; case .twoAxisGrid(let x, let y, _, _, _, _): return [x, y] }
    }
    public var values: [ControlValue] {
        switch self { case .constant(let v): return [v]; case .singleAxis(_, let nodes, _): return nodes.map(\.value); case .twoAxisGrid(_, _, _, _, let values, _): return values }
    }
}
/// 从独立观测轴计算一个注册目标的完整控制值。
public struct ResponseProgram: Codable, Equatable, Sendable {
    public var target: String
    public var expression: ResponseExpression
    public var missing: MissingObservationPolicy
    public init(target: String, expression: ResponseExpression, missing: MissingObservationPolicy = .reject) {
        self.target = target; self.expression = expression; self.missing = missing
    }
    public func validate() throws {
        let spec = try ParameterSpecification.lookup(target)
        guard spec.bindable else { throw LabError.invalid("Non-bindable response target") }
        for value in expression.values { try spec.validate(value) }
        func positions(_ values: [Double], axis: ObservationAxis) throws {
            guard (2...32).contains(values.count) else { throw LabError.invalid("Response axes require 2...32 nodes") }
            for value in values { try axis.validate(value) }
            guard zip(values, values.dropFirst()).allSatisfy({ axis.coordinate($0) < axis.coordinate($1) && (axis.coordinate($1) - axis.coordinate($0)).isFinite }) else {
                throw LabError.invalid("Response nodes must increase strictly")
            }
        }
        switch expression {
        case .constant: break
        case .singleAxis(let axis, let nodes, _): try positions(nodes.map(\.position), axis: axis)
        case .twoAxisGrid(let xa, let ya, let x, let y, let values, _):
            guard xa != ya, values.count == x.count * y.count else { throw LabError.invalid("Invalid two-axis grid shape") }
            try positions(x, axis: xa); try positions(y, axis: ya)
        }
        switch missing {
        case .reject: break
        case .constant(let value): try spec.validate(value)
        case .hold(let age): guard age.isFinite, age > 0 else { throw LabError.invalid("Hold age must be finite and positive") }
        }
    }
}
