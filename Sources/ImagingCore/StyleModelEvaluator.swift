import Foundation

/// 在 CPU 上将观测包和目标条件求值为自动控制及其来源记录。
public enum StyleModelEvaluator {
    /// Explicit locks supply only missing controls; valid observations still evaluate normally.
    /// Lock fallback retains original validity and does not bypass packet/domain validation.
    public static func evaluate(_ model: CompiledStyleModel, context: EvaluationContext, lockedControls: [ControlOverride] = []) throws -> AutomaticControls {
        try ParameterSpecification.validateOwners(lockedControls.map(\.target))
        for lock in lockedControls {
            guard model.definition.edits.overrideTargets.contains(lock.target) else { throw LabError.invalid("Unsupported locked control") }
            try ParameterSpecification.lookup(lock.target).validate(lock.value, effective: true)
            if case .resourceWeights(let weights) = lock.value {
                guard weights.allSatisfy({ model.lutResourceIDs.contains($0.resourceID) }) else { throw LabError.invalid("Unresolved locked LUT resource") }
            }
        }
        try context.evaluationStamp.validate(); try context.observations.validate(); try context.targetConditions.validate()
        for range in model.definition.compatibility.targetConditions {
            guard let value = context.targetConditions[range.axis], range.bounds.contains(value) else {
                throw LabError.invalid("Missing or incompatible target condition: \(range.axis.rawValue)")
            }
        }
        let observations = context.observations, now = context.evaluationStamp
        let age = try elapsed(from: observations.stamp, to: now)
        let validity = model.definition.observations.validity
        guard age <= validity.maxAgeSeconds, now.index - observations.stamp.index <= validity.maxAgeFrames,
              observations.featureDigest == model.featureDigest else { throw LabError.invalid("Observation identity or declared age mismatch") }
        var parameters = model.definition.appearance.parameters, weights = model.definition.appearance.lutWeights
        var provenance: [ControlProvenance] = [], diagnostics: [ControlDiagnostic] = []
        var usesLockedFallback = false
        if let legacy = model.legacy {
            let result = try StyleEvaluator.evaluate(legacy, conditions: observations.captureConditions)
            parameters = result.parameters
            diagnostics = result.diagnostics.map { .init(code: $0.status == .applied ? .legacyApplied : .legacyMissingCondition, target: $0.target.rawValue) }
        } else {
            for instruction in model.instructions {
                var inputs: [Double] = []
                for axis in instruction.expression.axes {
                    let input: Double?
                    switch axis {
                    case .source(let a): input = observations.captureConditions[a]
                    case .target(let a): input = context.targetConditions[a]
                    case .feature(let id): input = observations.features.first { $0.id == id }?.value
                    }
                    if let input { try axis.validate(input); inputs.append(axis.coordinate(input)) }
                }
                let value: ControlValue
                var validStamp: FrameStamp? = observations.stamp
                var fallback = false
                var lockedFallback = false
                if inputs.count == instruction.expression.axes.count {
                    value = try sample(instruction.expression, inputs: inputs)
                    if instruction.expression.axes.isEmpty { validStamp = now }
                } else {
                    fallback = true
                    if let lock = lockedControls.first(where: { $0.target == instruction.target }) {
                        value = lock.value
                        validStamp = priorValidStamp(model, context: context, target: instruction.target)
                        lockedFallback = true; usesLockedFallback = true
                    } else {
                        switch instruction.missing {
                        case .reject: throw LabError.invalid("Missing observation for \(instruction.target)")
                        case .constant(let constant):
                            value = constant
                            validStamp = priorValidStamp(model, context: context, target: instruction.target)
                        case .hold(let maximumAge):
                            guard let history = context.fallback else { throw LabError.invalid("No valid history for \(instruction.target)") }
                            let previous = history.controls
                            try previous.parameters.validate(); try ResourceWeight.validate(previous.lutWeights)
                            guard previous.modelID == model.identity, previous.sourceID == observations.sourceID,
                                  previous.calibrationID == observations.calibrationID, previous.featureDigest == observations.featureDigest else {
                                throw LabError.invalid("Fallback content identity mismatch")
                            }
                            _ = try elapsed(from: history.stamp, to: now)
                            let entries = previous.provenance.filter { $0.target == instruction.target }
                            guard entries.count == 1 else { throw LabError.invalid("Missing or duplicate fallback provenance") }
                            guard let originalStamp = entries[0].lastValidStamp else { throw LabError.invalid("Fallback has never been valid") }
                            validStamp = originalStamp
                            _ = try elapsed(from: originalStamp, to: history.stamp)
                            // 保持期限从最后一次有效观测起算，连续保持不会刷新期限。
                            guard try elapsed(from: originalStamp, to: now) <= maximumAge else { throw LabError.invalid("Fallback expired for \(instruction.target)") }
                            value = try ControlAccess.value(target: instruction.target, parameters: previous.parameters, lutWeights: previous.lutWeights)
                            // A caller cannot inject history outside this program's compiled domain.
                            try validateHeld(value, instruction: instruction)
                        }
                    }
                    diagnostics.append(.init(code: .missingObservation, target: instruction.target,
                                             message: lockedFallback ? "Using explicit locked value" : "Using declared fallback"))
                }
                try ControlAccess.apply(value, target: instruction.target, parameters: &parameters, lutWeights: &weights, effective: lockedFallback)
                provenance.append(.init(target: instruction.target, lastValidStamp: validStamp, isFallback: fallback))
            }
        }
        try parameters.validate(resolved: model.legacy != nil || usesLockedFallback); try ResourceWeight.validate(weights)
        var result = AutomaticControls(parameters: parameters, lutWeights: weights, modelID: model.identity, sourceID: observations.sourceID, calibrationID: observations.calibrationID, featureDigest: observations.featureDigest)
        result.provenance = provenance; result.diagnostics = diagnostics
        return result
    }

    /// Constant fallback may retain provenance, but never creates fresh evidence.
    private static func priorValidStamp(_ model: CompiledStyleModel, context: EvaluationContext, target: String) -> FrameStamp? {
        guard let history = context.fallback else { return nil }
        let controls = history.controls, observation = context.observations
        let entries = controls.provenance.filter { $0.target == target }
        guard controls.modelID == model.identity, controls.sourceID == observation.sourceID,
              controls.calibrationID == observation.calibrationID, controls.featureDigest == observation.featureDigest,
              entries.count == 1, let stamp = entries[0].lastValidStamp,
              (try? elapsed(from: stamp, to: history.stamp)) != nil,
              (try? elapsed(from: history.stamp, to: context.evaluationStamp)) != nil else { return nil }
        return stamp
    }

    private static func elapsed(from old: FrameStamp, to new: FrameStamp) throws -> Double {
        try old.validate(); try new.validate()
        let age = new.presentationTime - old.presentationTime
        guard old.streamID == new.streamID, old.generation == new.generation, old.index <= new.index,
              age.isFinite, age >= 0,
              (old.index != new.index || old == new) else { throw LabError.invalid("Frame identity or chronology mismatch") }
        return age
    }
    private static func validateHeld(_ value: ControlValue, instruction: ResponseProgram) throws {
        try ParameterSpecification.lookup(instruction.target).validate(value)
        try ControlInterpolation.validateEnvelope(value, anchors: instruction.expression.values)
    }
    private static func bracket(_ value: Double, positions: [Double], axis: ObservationAxis, boundary: ResponseBoundaryPolicy) throws -> (Int, Double) {
        let coordinates = positions.map { axis.coordinate($0) }
        if boundary == .reject && (value < coordinates[0] || value > coordinates[coordinates.count - 1]) { throw LabError.invalid("Observation outside response domain") }
        let clamped = min(coordinates.last!, max(coordinates[0], value))
        let upper = coordinates.firstIndex { $0 >= clamped } ?? (coordinates.count - 1)
        let lower = max(0, upper - 1)
        let t = (clamped - coordinates[lower]) / (coordinates[lower + 1] - coordinates[lower])
        return (lower, t)
    }
    private static func sample(_ expression: ResponseExpression, inputs: [Double]) throws -> ControlValue {
        switch expression {
        case .constant(let value): return value
        case .singleAxis(let axis, let nodes, let boundary):
            let (i, t) = try bracket(inputs[0], positions: nodes.map(\.position), axis: axis, boundary: boundary)
            return try ControlInterpolation.blend([nodes[i].value, nodes[i + 1].value], weights: [1-t, t])
        case .twoAxisGrid(let xa, let ya, let x, let y, let values, let boundary):
            let (ix, tx) = try bracket(inputs[0], positions: x, axis: xa, boundary: boundary)
            let (iy, ty) = try bracket(inputs[1], positions: y, axis: ya, boundary: boundary)
            let first = iy * x.count + ix, second = first + x.count
            return try ControlInterpolation.blend([values[first], values[first+1], values[second], values[second+1]], weights: [(1-tx)*(1-ty), tx*(1-ty), (1-tx)*ty, tx*ty])
        }
    }
}
