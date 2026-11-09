import Foundation

/// Immutable, bounded program. Its grammar cannot reference another output control,
/// so control-dependency cycles are unrepresentable rather than scheduled at runtime.
public struct CompiledCameraModel: Sendable {
    public let definition: CameraModel
    /// 完整模型定义的内容摘要。
    public let identity: String
    public var modelDigest: String { identity }
    /// 已声明特征规格的内容摘要，用来校验观测包采用了同一组统计口径。
    public let featureDigest: String
    public let sourceDependencies: Set<ConditionAxis>
    public let targetDependencies: Set<ConditionAxis>
    public let featureDependencies: Set<String>
    public let instructions: [ResponseProgram]
    public let temporalPolicy: TemporalPolicy
    /// Complete compatible palette, including resources selectable by editable weights.
    public let lutResourceIDs: Set<String>
    let legacy: CompiledStyleDefinition?

    fileprivate init(_ model: CameraModel, lutResourceIDs: Set<String>) throws {
        self.lutResourceIDs = lutResourceIDs
        definition = model; identity = try model.digest()
        featureDigest = try model.observations.featureDigest()
        instructions = model.responses
        temporalPolicy = model.legacyProfile?.temporalPolicy ?? model.appearance.temporalPolicy
        var source = Set<ConditionAxis>(), target = Set<ConditionAxis>(), features = Set<String>()
        for axis in model.responses.flatMap({ $0.expression.axes }) {
            switch axis {
            case .source(let a): source.insert(a)
            case .target(let a): target.insert(a)
            case .feature(let id): features.insert(id)
            }
        }
        if let profile = model.legacyProfile {
            legacy = try StyleEvaluator.compile(profile)
            source.formUnion(profile.responses.map(\.axis))
        } else { legacy = nil }
        sourceDependencies = source; targetDependencies = target; featureDependencies = features
    }
}

/// Shared typed storage access, used by automatic response, editing and adaptation.
public enum ControlAccess {
    /// 按目标 ID 读取整个控制值。LUT 权重独立于风格参数存储。
    public static func value(target: String, parameters: StyleParameters, lutWeights: [ResourceWeight]) throws -> ControlValue {
        switch target {
        case "color.matrix": return .matrix(parameters.color.matrix)
        case "tone.curve": return .curve(parameters.tone.curve)
        case "style.lutWeights": return .resourceWeights(lutWeights)
        default:
            guard let descriptor = ParameterDescriptor.all.first(where: { $0.id == target }) else { throw LabError.invalid("Unknown control: \(target)") }
            return .scalar(parameters[keyPath: descriptor.keyPath])
        }
    }
    /// 先验证目标形状及范围，再写入对应存储。默认使用声明范围；解析后的标量控制可选择有效范围。
    public static func apply(_ value: ControlValue, target: String, parameters: inout StyleParameters, lutWeights: inout [ResourceWeight], effective: Bool = false) throws {
        try ParameterSpecification.lookup(target).validate(value, effective: effective)
        switch (target, value) {
        case ("color.matrix", .matrix(let matrix)): parameters.color.matrix = matrix
        case ("tone.curve", .curve(let curve)): parameters.tone.curve = curve
        case ("style.lutWeights", .resourceWeights(let weights)): lutWeights = weights
        case (_, .scalar(let number)):
            guard let descriptor = ParameterDescriptor.all.first(where: { $0.id == target }) else { throw LabError.invalid("Unknown scalar control: \(target)") }
            parameters[keyPath: descriptor.keyPath] = number
        default: throw LabError.invalid("Incorrect control shape: \(target)")
        }
    }
}

/// 在逐帧求值前验证自动响应、时间插值端点及 LUT 调色板的兼容性。
public enum CameraModelCompiler {
    /// 从模型声明生成不可变求值程序，并提取观测依赖和可用 LUT 集合。
    public static func compile(_ model: CameraModel) throws -> CompiledCameraModel {
        try model.validate()
        guard model.responses.count <= ParameterSpecification.all.count else { throw LabError.invalid("Response instruction limit exceeded") }
        var baseline = model.appearance.parameters, weights = model.appearance.lutWeights
        var ranges: [String: ClosedRange<Double>] = [:]
        for instruction in model.responses {
            let spec = try ParameterSpecification.lookup(instruction.target)
            if spec.shape != .scalar {
                if case .constant(let value) = instruction.expression {
                    try ControlAccess.apply(value, target: spec.id, parameters: &baseline, lutWeights: &weights)
                } else {
                    var anchors = instruction.expression.values
                    if case .constant(let fallback) = instruction.missing { anchors.append(fallback) }
                    for rule in model.adaptation.rules where rule.target == spec.id {
                        if case .constant(let value) = rule.initialization { anchors.append(value) }
                        if case .constant(let value) = rule.expired { anchors.append(value) }
                    }
                    for value in anchors {
                        if case .curve(let curve) = value { _ = try ControlInterpolation.canonicalKnots(curve) }
                        if case .resourceWeights(let weights) = value, weights.isEmpty { throw LabError.invalid("Dynamic LUT anchors require convex weights") }
                    }
                    // This owner always replaces the appearance value. Use a legal
                    // representative for shape/strength checks, not an unused base.
                    try ControlAccess.apply(instruction.expression.values[0], target: spec.id, parameters: &baseline, lutWeights: &weights)
                }
                continue
            }
            var values = instruction.expression.values
            if case .constant(let fallback) = instruction.missing { values.append(fallback) }
            let numbers = values.compactMap { if case .scalar(let n) = $0 { return n }; return nil }
            ranges[spec.id] = numbers.min()!...numbers.max()!
        }
        // Independent interval bounds deliberately over-approximate correlated axes.
        // This proves all interpolation and missing-value combinations satisfy the
        // same cross-control constraints as StyleParameters.validate().
        func bounds(_ id: String) throws -> ClosedRange<Double> {
            if let range = ranges[id] { return range }
            guard case .scalar(let n) = try ControlAccess.value(target: id, parameters: baseline, lutWeights: weights) else { throw LabError.invalid("Expected scalar") }
            return n...n
        }
        for (low, high) in [("detail.fineSigma", "detail.midSigma"), ("glow.nearSigma", "glow.farSigma")] {
            guard try bounds(low).upperBound <= bounds(high).lowerBound else { throw LabError.invalid("Response extrema violate \(low) <= \(high)") }
        }
        for point in ["source", "destination"] {
            let x = try bounds("color.whiteBalance.\(point).x"), y = try bounds("color.whiteBalance.\(point).y")
            guard x.lowerBound > 0, y.lowerBound > 0, x.upperBound + y.upperBound < 1 else { throw LabError.invalid("Response extrema produce invalid \(point) white point") }
        }
        for rule in model.adaptation.rules {
            var endpoints: [ControlValue]
            if let response = model.responses.first(where: { $0.target == rule.target }) {
                endpoints = response.expression.values
                if case .constant(let value) = response.missing { endpoints.append(value) }
            } else { endpoints = [try ControlAccess.value(target: rule.target, parameters: baseline, lutWeights: weights)] }
            if case .constant(let value) = rule.initialization { endpoints.append(value) }
            if case .constant(let value) = rule.expired { endpoints.append(value) }
            try ControlInterpolation.validateTemporalEndpoints(endpoints)
            if rule.target == "tone.curve", model.edits.overrideTargets.contains(rule.target) {
                for value in endpoints { if case .curve(let curve) = value { _ = try ControlInterpolation.canonicalKnots(curve) } }
            }
        }
        let palette = try validatePalette(model)
        if let strength = model.edits.strength {
            try EditResolver.validateStrength(strength, parameters: baseline, lutWeights: weights,
                                              resources: model.appearance.resources)
        }
        return try CompiledCameraModel(model, lutResourceIDs: palette)
    }
    /// Initial execution palette is capped globally, not merely per interpolation
    /// cell, so temporal blending across cells cannot accumulate more than four LUTs.
    private static func validatePalette(_ model: CameraModel) throws -> Set<String> {
        var values = model.responses.flatMap { $0.expression.values }
        for response in model.responses { if case .constant(let value) = response.missing { values.append(value) } }
        for rule in model.adaptation.rules {
            if case .constant(let value) = rule.initialization { values.append(value) }
            if case .constant(let value) = rule.expired { values.append(value) }
        }
        values.append(.resourceWeights(model.appearance.lutWeights))
        if let strength = model.edits.strength { values.append(.resourceWeights(strength.neutralLUTWeights)) }
        var ids = Set(values.flatMap { value -> [String] in
            if case .resourceWeights(let weights) = value { return weights.map(\.resourceID) }; return []
        })
        if model.edits.overrideTargets.contains("style.lutWeights") {
            ids.formUnion(model.appearance.resources.filter { $0.role == .styleLUT }.map(\.id))
        }
        guard ids.count <= 4 else { throw LabError.unsupported("The model's complete LUT palette is limited to four resources") }
        let resources = model.appearance.resources.filter { ids.contains($0.id) }
        guard resources.count == ids.count else { throw LabError.invalid("Unresolved LUT palette") }
        if let first = resources.first {
            guard resources.allSatisfy({ $0.role == .styleLUT && $0.inputDomain == first.inputDomain && $0.outputDomain == first.outputDomain && $0.dimension == first.dimension && $0.channels == first.channels && $0.inputBounds == first.inputBounds && $0.outOfRange == first.outOfRange }) else {
                throw LabError.invalid("LUT palette requires matching domains, dimensions and boundary semantics")
            }
        }
        return ids
    }
}

/// Exact convex interpolation shared by response evaluation and temporal adaptation.
/// Dynamic curves accept only the canonical grid; no approximation is performed.
public enum ControlInterpolation {
    public static func canonicalKnots(_ curve: ResponseCurve) throws -> [ResponseKnot] {
        try curve.validate(kind: .tone)
        guard case .points(let knots, .linear) = curve.shape, knots.count == 32,
              knots.enumerated().allSatisfy({ $0.element.x == Double($0.offset) / 31 }) else {
            throw LabError.unsupported("Dynamic curves require exactly 32 uniform linear knots; approximation is not performed")
        }
        return knots
    }
    private static func shape(_ value: ControlValue) -> Int {
        switch value { case .scalar: return 0; case .matrix: return 1; case .curve: return 2; case .resourceWeights: return 3 }
    }
    private static func components(_ value: ControlValue, ids: [String]) throws -> [Double] {
        switch value {
        case .scalar(let v): guard v.isFinite else { throw LabError.invalid("Nonfinite scalar") }; return [v]
        case .matrix(let m): try m.validate(); return m.values
        case .curve(let c): return try canonicalKnots(c).map(\.y)
        case .resourceWeights(let weights):
            try ResourceWeight.validate(weights)
            guard weights.allSatisfy({ ids.contains($0.resourceID) }) else { throw LabError.invalid("Foreign LUT resource") }
            let total = weights.reduce(0) { $0 + $1.weight }
            return ids.map { id in (weights.first { $0.resourceID == id }?.weight ?? 0) / (total == 0 ? 1 : total) }
        }
    }
    private static func ids(_ values: [ControlValue]) throws -> [String] {
        let ids = Set(values.flatMap { value -> [String] in if case .resourceWeights(let w) = value { return w.map(\.resourceID) }; return [] }).sorted()
        guard ids.count <= 4 else { throw LabError.unsupported("A convex blend is limited to four LUT resources") }; return ids
    }
    /// Validates all values that may meet at a temporal transition. An unchanged
    /// analytic curve remains exact; differing curve endpoints require the fixed grid.
    public static func validateTemporalEndpoints(_ values: [ControlValue]) throws {
        guard let first = values.first, values.allSatisfy({ shape($0) == shape(first) }) else { throw LabError.invalid("Mismatched temporal endpoint shapes") }
        let ids = try ids(values)
        if case .curve = first, values.allSatisfy({ $0 == first }) { return }
        if case .resourceWeights = first {
            let empty = values.map { if case .resourceWeights(let w) = $0 { return w.isEmpty }; return false }
            guard empty.allSatisfy({ $0 == empty[0] }) else { throw LabError.invalid("Temporal LUT endpoints must all be convex or all empty") }
        }
        for value in values { _ = try components(value, ids: ids) }
    }
    public static func blend(_ values: [ControlValue], weights: [Double]) throws -> ControlValue {
        guard (1...4).contains(values.count), values.count == weights.count,
              weights.allSatisfy({ $0.isFinite && $0 >= 0 }), abs(weights.reduce(0,+) - 1) <= 1e-9,
              let first = values.first, values.allSatisfy({ shape($0) == shape(first) }) else { throw LabError.invalid("Invalid convex interpolation") }
        let ids = try ids(values)
        if case .resourceWeights = first {
            let empty = values.map { if case .resourceWeights(let w) = $0 { return w.isEmpty }; return false }
            guard empty.allSatisfy({ $0 == empty[0] }) else { throw LabError.unsupported("LUT interpolation needs both convex endpoints") }
        }
        let components = try values.map { try components($0, ids: ids) }
        let total = weights.reduce(0,+), normalized = weights.map { $0 / total }
        let mixed = (0..<components[0].count).map { i -> Double in
            let column = components.map { $0[i] }
            let value = zip(column, normalized).reduce(0) { $0 + $1.0 * $1.1 }
            return min(column.max()!, max(column.min()!, value))
        }
        switch first {
        case .scalar: return .scalar(mixed[0])
        case .matrix:
            let matrix = ColorMatrix3x3(values: mixed); try matrix.validate(); return .matrix(matrix)
        case .curve:
            let curve = ResponseCurve(knots: mixed.enumerated().map { .init(x: Double($0.offset)/31, y: $0.element) })
            try curve.validate(kind: .tone); return .curve(curve)
        case .resourceWeights:
            let sum = mixed.reduce(0,+)
            let result = zip(ids, mixed).map { ResourceWeight(resourceID: $0.0, weight: $0.1 / (sum == 0 ? 1 : sum)) }
            try ResourceWeight.validate(result); return .resourceWeights(result)
        }
    }
    public static func distance(_ a: ControlValue, _ b: ControlValue) throws -> Double {
        if a == b { return 0 }
        guard shape(a) == shape(b) else { throw LabError.invalid("Mismatched control shapes") }
        let ids = try ids([a,b])
        let left = try components(a, ids: ids), right = try components(b, ids: ids)
        return zip(left,right).map { abs($0-$1) }.max() ?? 0
    }
    static func validateEnvelope(_ value: ControlValue, anchors: [ControlValue]) throws {
        guard !anchors.isEmpty, anchors.allSatisfy({ shape($0) == shape(value) }) else { throw LabError.invalid("Mismatched fallback shape") }
        if case .resourceWeights(let weights) = value, weights.isEmpty {
            guard anchors.allSatisfy({ if case .resourceWeights(let w) = $0 { return w.isEmpty }; return false }) else { throw LabError.invalid("Missing convex LUT history") }
        }
        let ids = try ids(anchors), candidate = try components(value, ids: ids)
        let bounds = try anchors.map { try components($0, ids: ids) }
        for i in candidate.indices {
            let column = bounds.map { $0[i] }
            guard candidate[i] >= column.min()! - 1e-12, candidate[i] <= column.max()! + 1e-12 else { throw LabError.invalid("Fallback outside compiled response range") }
        }
    }
}
