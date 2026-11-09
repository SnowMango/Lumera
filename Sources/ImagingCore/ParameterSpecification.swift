import Foundation

public enum ParameterShape: String, Codable, Sendable { case scalar, matrix3x3, curve, resourceWeights }
public enum ParameterInterpolation: String, Codable, Sendable { case linear, monotoneCurve, convexWeights }
public enum ParameterChangeClass: String, Codable, Sendable { case uniform, spatialKernel, curveResource, lutBlend }

/// CPU-only parameter metadata. Legacy writable key paths remain in ParameterDescriptor.
public struct ParameterSpecification: Equatable, Sendable {
    public let id: String
    public let shape: ParameterShape
    /// 模型声明值的范围。
    public let baseRange: ClosedRange<Double>
    /// 运行时已解析控制可使用的范围，可能与声明值范围不同。
    public let effectiveRange: ClosedRange<Double>
    public let unit: ParameterUnit
    public let allowedOperations: [ResponseOperation]
    public let interpolation: ParameterInterpolation
    public let changeClass: ParameterChangeClass
    public let editable: Bool
    public let bindable: Bool
    public var legacyBindable: Bool { !allowedOperations.isEmpty }
    public var ownershipDomain: String { id.hasPrefix("color.matrix.") ? "color.matrix" : id }

    private static let legacyTargets: Set<String> = [
        "noise.gain", "noise.chromaRatio", "grain.amount", "grain.size", "grain.roughness", "grain.chroma",
        "softening.amount", "softening.sigma", "detail.fineGain", "detail.midGain", "detail.sharpenAmount",
        "glow.amount", "glow.threshold", "halation.amount", "halation.threshold", "halation.radius", "vignette.amountEV"
    ]
    public static let all: [Self] = ParameterDescriptor.all.map { d in
        Self(id: d.id, shape: .scalar, baseRange: d.baseRange, effectiveRange: d.effectiveRange, unit: d.unit,
             allowedOperations: legacyTargets.contains(d.id) ? (d.id == "noise.gain" ? [.multiply] : [.replace, .multiply, .add]) : [],
             interpolation: .linear, changeClass: d.unit == .referencePixels ? .spatialKernel : .uniform,
             editable: true, bindable: true)
    } + [
        Self(id: "color.matrix", shape: .matrix3x3, baseRange: -4...4, effectiveRange: -4...4, unit: .matrixCoefficient,
             allowedOperations: [], interpolation: .linear, changeClass: .uniform, editable: true, bindable: true),
        Self(id: "tone.curve", shape: .curve, baseRange: 0...1, effectiveRange: 0...1, unit: .normalized,
             allowedOperations: [], interpolation: .monotoneCurve, changeClass: .curveResource, editable: true, bindable: true),
        Self(id: "style.lutWeights", shape: .resourceWeights, baseRange: 0...1, effectiveRange: 0...1, unit: .normalized,
             allowedOperations: [], interpolation: .convexWeights, changeClass: .lutBlend, editable: true, bindable: true)
    ]
    private static let index = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    /// 按完整目标 ID 查找规格；未知 ID 会抛错。
    public static func lookup(_ id: String) throws -> Self {
        guard let value = index[id] else { throw LabError.invalid("Unknown parameter: \(id)") }
        return value
    }
    /// 检查 ID 唯一、范围有限且有效范围涵盖声明范围。
    public static func validateRegistry(_ entries: [Self]) throws {
        guard Set(entries.map(\.id)).count == entries.count,
              entries.allSatisfy({ !$0.id.isEmpty && $0.baseRange.lowerBound.isFinite && $0.baseRange.upperBound.isFinite &&
                  $0.effectiveRange.lowerBound.isFinite && $0.effectiveRange.upperBound.isFinite &&
                  $0.effectiveRange.contains($0.baseRange.lowerBound) && $0.effectiveRange.contains($0.baseRange.upperBound) }) else {
            throw LabError.invalid("Invalid or duplicate parameter specification")
        }
    }
    /// A block and one of its components cannot both write the same storage.
    /// 同一目标只能出现一次；独立矩阵分量可分别拥有写入者。
    public static func validateOwners(_ targets: [String]) throws {
        var owners = Set<String>()
        for target in targets {
            let domain = try lookup(target).ownershipDomain
            let conflict = target == domain
                ? owners.contains(where: { $0 == domain || $0.hasPrefix(domain + ".") })
                : owners.contains(domain) || owners.contains(target)
            guard !conflict else { throw LabError.invalid("Overlapping parameter owners: \(target)") }
            owners.insert(target)
        }
    }
    public func validate(_ value: ControlValue, effective: Bool = false) throws {
        let range = effective ? effectiveRange : baseRange
        switch (shape, value) {
        case (.scalar, .scalar(let v)):
            guard v.isFinite, range.contains(v) else { throw LabError.invalid("\(id): value outside legal range") }
        case (.matrix3x3, .matrix(let m)): try m.validate()
        case (.curve, .curve(let c)): try c.validate(kind: .tone)
        case (.resourceWeights, .resourceWeights(let weights)): try ResourceWeight.validate(weights)
        default: throw LabError.invalid("\(id): incorrect value shape")
        }
    }
}

/// 与目标规格对应的控制值，可用于自动响应、编辑或时间适应。
public enum ControlValue: Codable, Equatable, Sendable {
    case scalar(Double)
    case matrix(ColorMatrix3x3)
    case curve(ResponseCurve)
    case resourceWeights([ResourceWeight])
}
/// 引用模型中声明的资源；非空权重集合须构成凸组合。
public struct ResourceWeight: Codable, Equatable, Sendable {
    public var resourceID: String
    public var weight: Double
    public init(resourceID: String, weight: Double) { self.resourceID = resourceID; self.weight = weight }
    public static func validate(_ values: [Self]) throws {
        guard Set(values.map(\.resourceID)).count == values.count,
              values.allSatisfy({ !$0.resourceID.isEmpty && $0.weight.isFinite && (0...1).contains($0.weight) }),
              values.isEmpty || abs(values.reduce(0) { $0 + $1.weight } - 1) <= 1e-9 else {
            throw LabError.invalid("Resource weights must be unique, nonnegative and sum to one")
        }
    }
}
