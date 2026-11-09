import Foundation

/// Caller-owned history for one source stream. No clocks or global caches participate.
public struct AdaptationState: Codable, Equatable, Sendable {
    public let controls: AutomaticControls
    public let stamp: FrameStamp
    public let policyDigest: String
    /// 按目标记录缺测计时起点，使用该流的呈现时间（秒）。
    public let missingSince: [String: Double]
    public let locks: [ControlOverride]
    public init(controls: AutomaticControls, stamp: FrameStamp, policyDigest: String, missingSince: [String: Double] = [:], locks: [ControlOverride] = []) {
        self.controls = controls; self.stamp = stamp; self.policyDigest = policyDigest
        self.missingSince = missingSince; self.locks = locks
    }
}
/// 一次状态转换的有效控制与下一帧可用的历史。
public struct AdaptationResult: Codable, Equatable, Sendable {
    public let controls: AutomaticControls
    public let state: AdaptationState
    public init(controls: AutomaticControls, state: AdaptationState) { self.controls = controls; self.state = state }
}

/// 仅依据调用方提供的控制、时间戳和历史计算跨帧适应。
public enum AdaptationReducer {
    /// 沿用历史时要求内容身份、流世代和策略一致，且索引与呈现时间严格递增。
    /// 显式重置丢弃历史，包括缺测计时和锁定。
    public static func reduce(_ controls: AutomaticControls, state: AdaptationState?, stamp: FrameStamp, event: AdaptationEvent?, policy: AdaptationPolicy) throws -> AdaptationResult {
        try stamp.validate(); try policy.validate(); try validate(controls, at: stamp)
        let digest = try StyleIdentity.digest(policy)
        let reset: Bool
        if case .reset = event { reset = true } else { reset = false }
        let previous = reset ? nil : state
        let elapsed = previous.map { stamp.presentationTime - $0.stamp.presentationTime } ?? 0
        if let previous {
            guard elapsed.isFinite, elapsed > 0 else { throw LabError.invalid("Invalid temporal elapsed time") }
            try previous.stamp.validate(); try validate(previous.controls, at: previous.stamp)
            try ParameterSpecification.validateOwners(previous.locks.map(\.target))
            for lock in previous.locks { try ParameterSpecification.lookup(lock.target).validate(lock.value, effective: true) }
            guard previous.policyDigest == digest,
                  previous.controls.modelID == controls.modelID, previous.controls.sourceID == controls.sourceID,
                  previous.controls.calibrationID == controls.calibrationID, previous.controls.featureDigest == controls.featureDigest,
                  previous.stamp.streamID == stamp.streamID, previous.stamp.generation == stamp.generation,
                  previous.stamp.index < stamp.index, previous.stamp.presentationTime < stamp.presentationTime,
                  previous.missingSince.allSatisfy({ key, value in policy.rules.contains(where: { $0.target == key }) && value.isFinite && value <= previous.stamp.presentationTime }) else {
                throw LabError.invalid("Temporal history requires an explicit reset")
            }
            for rule in policy.rules {
                if let provenance = previous.controls.provenance.first(where: { $0.target == rule.target }), provenance.isFallback || provenance.lastValidStamp == nil {
                    guard let start = previous.missingSince[rule.target],
                          provenance.lastValidStamp == nil || start == provenance.lastValidStamp?.presentationTime else {
                        throw LabError.invalid("Missing temporal freshness history")
                    }
                } else if previous.missingSince[rule.target] != nil { throw LabError.invalid("Unexpected missing history") }
            }
            for lock in previous.locks {
                guard try read(lock.target, previous.controls) == lock.value else { throw LabError.invalid("Invalid stored lock") }
            }
        }
        var output = controls
        var missing = previous?.missingSince ?? [:]
        var locks = previous?.locks ?? []
        var unlocked: [ControlOverride] = []
        switch event {
        case .lock(let values):
            try ParameterSpecification.validateOwners(values.map(\.target))
            for value in values { locks.removeAll { $0.target == value.target }; locks.append(value) }
        case .unlock(let values):
            try ParameterSpecification.validateOwners(values.map(\.target))
            for value in values {
                guard let stored = locks.first(where: { $0.target == value.target }), stored == value else { throw LabError.invalid("Unlock must identify the stored locked value") }
                unlocked.append(stored); locks.removeAll { $0.target == value.target }
            }
        default: break
        }
        try ParameterSpecification.validateOwners(locks.map(\.target))
        for value in locks + unlocked where policy.rules.contains(where: { $0.target == value.target }) {
            if case .curve(let curve) = value.value { _ = try ControlInterpolation.canonicalKnots(curve) }
        }
        for rule in policy.rules {
            var target = try read(rule.target, controls)
            var endpoints = [target]
            if let previous { endpoints.append(try read(rule.target, previous.controls)) }
            if case .constant(let value) = rule.initialization { endpoints.append(value) }
            if case .constant(let value) = rule.expired { endpoints.append(value) }
            endpoints += (locks + unlocked).filter { $0.target == rule.target }.map(\.value)
            try ControlInterpolation.validateTemporalEndpoints(endpoints)
            var expired = false
            if let index = output.provenance.firstIndex(where: { $0.target == rule.target }) {
                var provenance = output.provenance[index]
                if provenance.isFallback || provenance.lastValidStamp == nil {
                    // A fallback is not evidence of a new observation, even when its packet is new.
                    if let old = previous?.controls.provenance.first(where: { $0.target == rule.target }) {
                        provenance.lastValidStamp = old.lastValidStamp
                    }
                    let start = provenance.lastValidStamp?.presentationTime ?? missing[rule.target] ?? stamp.presentationTime
                    let missingAge = stamp.presentationTime - start
                    guard missingAge.isFinite, missingAge >= 0 else { throw LabError.invalid("Invalid missing observation age") }
                    missing[rule.target] = start
                    if missingAge > rule.maximumMissingSeconds {
                        expired = true
                        switch rule.expired {
                        case .constant(let value): target = value
                        default:
                            guard locks.contains(where: { $0.target == rule.target }) || unlocked.contains(where: { $0.target == rule.target }) else {
                                throw LabError.invalid("Missing observation expired: \(rule.target)")
                            }
                        }
                        output.diagnostics.append(.init(code: .missingExpired, target: rule.target))
                    }
                    output.provenance[index] = provenance
                } else { missing.removeValue(forKey: rule.target) }
            } else { missing.removeValue(forKey: rule.target) }
            // 锁定优先；解锁帧保留原锁值。过期目标跳过平滑，其余才按历史平滑或初始化。
            let value: ControlValue
            if let lock = locks.first(where: { $0.target == rule.target }) { value = lock.value }
            else if let unlock = unlocked.first(where: { $0.target == rule.target }) { value = unlock.value }
            else if expired { value = target }
            else if let previous {
                let old = try read(rule.target, previous.controls)
                let alpha = rule.timeConstantSeconds == 0 ? 1 : -expm1(-elapsed / rule.timeConstantSeconds)
                value = try interpolate(old, target, alpha: alpha, hysteresis: rule.hysteresis)
            } else {
                switch rule.initialization { case .immediate: value = target; case .constant(let initial): value = initial }
            }
            try write(value, rule.target, &output)
        }
        for lock in locks { try write(lock.value, lock.target, &output) }
        for unlock in unlocked { try write(unlock.value, unlock.target, &output) }
        if reset { output.diagnostics.append(.init(code: .temporalReset)) }
        try validate(output, at: stamp)
        let next = AdaptationState(controls: output, stamp: stamp, policyDigest: digest, missingSince: missing, locks: locks.sorted { $0.target < $1.target })
        return .init(controls: output, state: next)
    }

    private static func read(_ target: String, _ controls: AutomaticControls) throws -> ControlValue {
        try ControlAccess.value(target: target, parameters: controls.parameters, lutWeights: controls.lutWeights)
    }
    private static func write(_ value: ControlValue, _ target: String, _ controls: inout AutomaticControls) throws {
        try ControlAccess.apply(value, target: target, parameters: &controls.parameters, lutWeights: &controls.lutWeights, effective: true)
    }
    private static func validate(_ controls: AutomaticControls, at stamp: FrameStamp) throws {
        try controls.parameters.validate(resolved: true); try ResourceWeight.validate(controls.lutWeights)
        guard controls.lutWeights.count <= 4 else { throw LabError.unsupported("Temporal LUT palette is limited to four resources") }
        guard [controls.modelID, controls.sourceID, controls.calibrationID, controls.featureDigest].allSatisfy({ !$0.isEmpty }),
              Set(controls.provenance.map(\.target)).count == controls.provenance.count else { throw LabError.invalid("Invalid temporal controls") }
        for p in controls.provenance {
            _ = try ParameterSpecification.lookup(p.target)
            if let valid = p.lastValidStamp {
                try valid.validate()
                guard valid.streamID == stamp.streamID, valid.generation == stamp.generation, valid.index <= stamp.index,
                      valid.presentationTime <= stamp.presentationTime else { throw LabError.invalid("Invalid temporal provenance") }
            } else if !p.isFallback { throw LabError.invalid("Valid controls require an observation stamp") }
        }
    }
    private static func interpolate(_ old: ControlValue, _ target: ControlValue, alpha: Double, hysteresis: Double) throws -> ControlValue {
        if old == target { return old }
        if alpha == 1, hysteresis == 0 { return target }
        if try ControlInterpolation.distance(old, target) <= hysteresis { return old }
        return try ControlInterpolation.blend([old, target], weights: [1-alpha, alpha])
    }
}
