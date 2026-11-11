import Foundation

/// Resolves temporary user edits without changing model or observation identity.
public enum EditResolver {
    /// 先混合整体强度，再合并视觉偏移，最后应用显式覆盖或锁定并检查约束。
    /// 输入曝光与白平衡作为独立字段传给渲染阶段。
    public static func resolve(_ edits: EditRequest, automatic: AutomaticControls, model: CompiledStyleModel) throws -> ResolvedControls {
        guard automatic.modelID == model.identity, automatic.featureDigest == model.featureDigest else { throw LabError.invalid("Edit model identity mismatch") }
        try automatic.parameters.validate(resolved: true)
        try validateResources(automatic.lutWeights, resources: model.definition.appearance.resources)
        guard automatic.lutWeights.allSatisfy({ model.lutResourceIDs.contains($0.resourceID) }) else { throw LabError.invalid("Automatic LUT weights are outside the compiled palette") }
        let capabilities = model.definition.edits
        guard edits.inputExposureEV.isFinite, (-10...10).contains(edits.inputExposureEV),
              capabilities.allowsInputExposure || edits.inputExposureEV == 0,
              capabilities.allowsInputWhiteBalance || edits.inputWhiteBalance == nil else { throw LabError.invalid("Unsupported input edit") }
        try edits.inputWhiteBalance?.validate()
        try ParameterSpecification.validateOwners((edits.overrides + edits.locks).map(\.target))
        guard Set(edits.visualOffsets.map(\.id)).count == edits.visualOffsets.count else { throw LabError.invalid("Duplicate visual offset") }
        var parameters = automatic.parameters, weights = automatic.lutWeights
        var diagnostics: [ControlDiagnostic] = []
        if let strength = edits.strength {
            guard strength.isFinite, (0...1).contains(strength), let definition = capabilities.strength else { throw LabError.invalid("Unsupported strength") }
            try validateStrength(definition, parameters: parameters, lutWeights: weights, resources: model.definition.appearance.resources)
            parameters = try interpolate(definition.neutralParameters, parameters, strength)
            weights = blendWeights(definition.neutralLUTWeights, weights, strength)
            diagnostics.append(.init(code: .strengthApplied))
        }
        var deltas: [String: Double] = [:]
        for offset in edits.visualOffsets.sorted(by: { $0.id < $1.id }) {
            guard let control = capabilities.visualControls.first(where: { $0.id == offset.id }), control.bounds.contains(offset.value) else { throw LabError.invalid("Unknown or invalid visual offset: \(offset.id)") }
            for link in control.links {
                let delta = (deltas[link.target] ?? 0) + offset.value * link.coefficient
                guard delta.isFinite else { throw LabError.invalid("Visual offset overflow") }
                deltas[link.target] = delta
            }
        }
        let offsetTargets = Set(deltas.keys)
        for target in deltas.keys.sorted() {
            guard case .scalar(let previous) = try ControlAccess.value(target: target, parameters: parameters, lutWeights: weights) else { throw LabError.invalid("Visual offsets require scalar targets") }
            let value = previous + deltas[target]!
            guard value.isFinite else { throw LabError.invalid("Visual offset overflow") }
            let range = try ParameterSpecification.lookup(target).effectiveRange
            let limited = min(range.upperBound, max(range.lowerBound, value))
            if limited != value { diagnostics.append(.init(code: .clamped, target: target)) }
            try ControlAccess.apply(.scalar(limited), target: target, parameters: &parameters, lutWeights: &weights, effective: true)
        }
        for edit in edits.overrides + edits.locks {
            guard capabilities.overrideTargets.contains(edit.target) else { throw LabError.invalid("Unsupported override: \(edit.target)") }
            if model.definition.adaptation.rules.contains(where: { $0.target == edit.target }) {
                if case .curve(let curve) = edit.value { _ = try ControlInterpolation.canonicalKnots(curve) }
                let automaticValue = try ControlAccess.value(target: edit.target, parameters: automatic.parameters, lutWeights: automatic.lutWeights)
                try ControlInterpolation.validateTemporalEndpoints([automaticValue, edit.value])
            }
            try ControlAccess.apply(edit.value, target: edit.target, parameters: &parameters, lutWeights: &weights, effective: true)
            if offsetTargets.contains(edit.target) || (edit.target == "color.matrix" && offsetTargets.contains(where: { $0.hasPrefix("color.matrix.") })) {
                diagnostics.append(.init(code: .overridden, target: edit.target))
            }
        }
        let locked = Set(edits.locks.map(\.target))
        let edited = Set((edits.overrides + edits.locks).map(\.target)).union(offsetTargets)
        try constrain(&parameters, weights: &weights, locked: locked, edited: edited, diagnostics: &diagnostics)
        try parameters.validate(resolved: true)
        try validateResources(weights, resources: model.definition.appearance.resources)
        guard weights.allSatisfy({ model.lutResourceIDs.contains($0.resourceID) }) else { throw LabError.invalid("Edited LUT weights are outside the compiled palette") }
        for lock in edits.locks {
            guard try ControlAccess.value(target: lock.target, parameters: parameters, lutWeights: weights) == lock.value else { throw LabError.invalid("Constraint changed a locked value") }
        }
        return .init(automatic: automatic, parameters: parameters, lutWeights: weights, inputExposureEV: edits.inputExposureEV, inputWhiteBalance: edits.inputWhiteBalance, lockedTargets: edits.locks.map(\.target), diagnostics: diagnostics)
    }

    private static func constrain(_ p: inout StyleParameters, weights: inout [ResourceWeight], locked: Set<String>, edited: Set<String>, diagnostics: inout [ControlDiagnostic]) throws {
        func read(_ id: String) throws -> Double {
            guard case .scalar(let value) = try ControlAccess.value(target: id, parameters: p, lutWeights: weights) else { throw LabError.invalid("Expected scalar constraint") }
            return value
        }
        func write(_ id: String, _ value: Double) throws {
            guard !locked.contains(id) else { throw LabError.invalid("Contradictory locked constraints") }
            try ControlAccess.apply(.scalar(value), target: id, parameters: &p, lutWeights: &weights, effective: true)
            diagnostics.append(.init(code: .constraintAdjusted, target: id))
        }
        // 修复耦合范围时优先保留锁定值，其次在可行时保留显式编辑的值。
        for (low, high) in [("detail.fineSigma", "detail.midSigma"), ("glow.nearSigma", "glow.farSigma")] {
            let a = try read(low), b = try read(high)
            if a > b {
                if locked.contains(high) || (!locked.contains(low) && edited.contains(high) && !edited.contains(low)) { try write(low, b) }
                else { try write(high, a) }
            }
        }
        for point in ["source", "destination"] {
            let xID = "color.whiteBalance.\(point).x", yID = "color.whiteBalance.\(point).y"
            let epsilon = 1e-9
            if try read(xID) <= 0 { try write(xID, epsilon) }
            if try read(yID) <= 0 { try write(yID, epsilon) }
            let x = try read(xID), y = try read(yID)
            if x + y >= 1 {
                let preserveX = locked.contains(xID) || (!locked.contains(yID) && edited.contains(xID))
                if preserveX {
                    guard x < 1 else { throw LabError.invalid("Locked white point has no legal counterpart") }
                    try write(yID, (1 - x) / 2)
                } else if locked.contains(yID) || edited.contains(yID) {
                    guard y < 1 else { throw LabError.invalid("Locked white point has no legal counterpart") }
                    try write(xID, (1 - y) / 2)
                } else {
                    try write(xID, x / (x + y) * (1 - epsilon))
                    try write(yID, y / (x + y) * (1 - epsilon))
                }
            }
        }
    }

    /// Checks that every intermediate strength has a representable, legal path.
    /// Arbitrary analytic-curve blends require a richer curve schema and are rejected.
    public static func validateStrength(_ definition: StrengthDefinition, parameters: StyleParameters, lutWeights: [ResourceWeight], resources: [ModelResourceDescriptor]) throws {
        let neutral = definition.neutralParameters
        try neutral.validate(resolved: true); try parameters.validate(resolved: true)
        guard !neutral.color.isActive, !neutral.tone.isActive, !neutral.detail.isActive, !neutral.softening.isActive,
              !neutral.vignette.isActive, !neutral.glow.isActive, !neutral.halation.isActive, !neutral.noise.isActive, !neutral.grain.isActive else { throw LabError.invalid("Strength endpoint is not neutral") }
        try validateResources(definition.neutralLUTWeights, resources: resources)
        try validateResources(lutWeights, resources: resources)
        guard definition.neutralLUTWeights.isEmpty == lutWeights.isEmpty else { throw LabError.invalid("Strength requires declared neutral LUT weights") }
        try interpolate(neutral, parameters, 0.5).validate(resolved: true)
    }

    private static func validateResources(_ weights: [ResourceWeight], resources: [ModelResourceDescriptor]) throws {
        try ResourceWeight.validate(weights)
        guard weights.allSatisfy({ weight in resources.contains(where: { $0.id == weight.resourceID && $0.role == .styleLUT }) }) else { throw LabError.invalid("Unresolved edit LUT") }
    }

    private static func blendWeights(_ a: [ResourceWeight], _ b: [ResourceWeight], _ t: Double) -> [ResourceWeight] {
        if t == 0 { return a }; if t == 1 { return b }
        return Set(a.map(\.resourceID) + b.map(\.resourceID)).sorted().map { id in
            .init(resourceID: id, weight: (a.first(where: { $0.resourceID == id })?.weight ?? 0) * (1 - t) + (b.first(where: { $0.resourceID == id })?.weight ?? 0) * t)
        }
    }

    private static func blendCurve(_ a: ResponseCurve, _ b: ResponseCurve, _ t: Double) throws -> ResponseCurve {
        if a == b { return a }
        // Identity can be represented exactly on any linear point grid.
        if a == .identity, case .points(let knots, .linear) = b.shape {
            return try blendCurve(.init(knots: knots.map { .init(x: $0.x, y: $0.x) }), b, t)
        }
        if b == .identity, case .points(let knots, .linear) = a.shape {
            return try blendCurve(a, .init(knots: knots.map { .init(x: $0.x, y: $0.x) }), t)
        }
        switch (a.shape, b.shape) {
        case (.function(let left), .function(let right)):
            var shape = left; shape.start = right.start; shape.end = right.end
            guard shape == right else { throw LabError.unsupported("Strength cannot exactly blend these analytic curves") }
            var result = left; result.start = left.start * (1 - t) + right.start * t; result.end = left.end * (1 - t) + right.end * t
            return .init(function: result)
        case (.points(let left, .linear), .points(let right, .linear)):
            guard left.map(\.x) == right.map(\.x) else { throw LabError.unsupported("Strength curves need matching knot coordinates") }
            return .init(knots: zip(left, right).map { .init(x: $0.x, y: $0.y * (1 - t) + $1.y * t) })
        default: throw LabError.unsupported("Strength curve blend is not representable")
        }
    }

    private static func interpolate(_ neutral: StyleParameters, _ current: StyleParameters, _ t: Double) throws -> StyleParameters {
        if t == 0 { return neutral }; if t == 1 { return current }
        var a = neutral, b = current
        // Disabled modules contribute their effective neutral amplitude, not stored values.
        func effective(_ p: inout StyleParameters) {
            if !p.detail.enabled { p.detail.fineGain = 1; p.detail.midGain = 1; p.detail.sharpenAmount = 0 }
            if !p.softening.enabled { p.softening.amount = 0 }
            if !p.vignette.enabled { p.vignette.amountEV = 0 }
            if !p.glow.enabled { p.glow.amount = 0 }
            if !p.halation.enabled { p.halation.amount = 0 }
            if !p.noise.enabled { p.noise.gain = 0 }
            if !p.grain.enabled { p.grain.amount = 0 }
            if !p.tone.enabled { p.tone.curve = .identity }
        }
        effective(&a); effective(&b)
        var result = b
        for descriptor in ParameterDescriptor.all { result[keyPath: descriptor.keyPath] = a[keyPath: descriptor.keyPath] * (1 - t) + b[keyPath: descriptor.keyPath] * t }
        result.tone.enabled = a.tone.enabled || b.tone.enabled
        result.detail.enabled = a.detail.enabled || b.detail.enabled
        result.softening.enabled = a.softening.enabled || b.softening.enabled
        result.vignette.enabled = a.vignette.enabled || b.vignette.enabled
        result.glow.enabled = a.glow.enabled || b.glow.enabled
        result.halation.enabled = a.halation.enabled || b.halation.enabled
        result.noise.enabled = a.noise.enabled || b.noise.enabled
        result.grain.enabled = a.grain.enabled || b.grain.enabled
        result.tone.curve = try blendCurve(a.tone.curve, b.tone.curve, t)
        // A zero-amplitude endpoint leaves its modulation curve unconstrained.
        result.noise.curve = a.noise.gain == 0 ? b.noise.curve : b.noise.gain == 0 ? a.noise.curve : try blendCurve(a.noise.curve, b.noise.curve, t)
        result.grain.luminanceCurve = a.grain.amount == 0 ? b.grain.luminanceCurve : b.grain.amount == 0 ? a.grain.luminanceCurve : try blendCurve(a.grain.luminanceCurve, b.grain.luminanceCurve, t)
        return result
    }
}
