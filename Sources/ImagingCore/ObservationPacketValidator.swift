import Foundation

/// Validates a whole observation packet; never patches old features with new capture facts.
public enum ObservationPacketValidator {
    @discardableResult
    /// 校验包与当前输入的内容身份、时间窗口和特征集合。延迟包还需通过采集条件差异检查。
    public static func validate(_ packet: FrameObservations, current: FrameInputFacts, requirements: ObservationRequirements) throws -> FrameObservations {
        try packet.validate(); try current.validate(); try requirements.validate()
        let old = packet.stamp, now = current.stamp
        let age = now.presentationTime - old.presentationTime
        guard packet.sourceID == current.sourceID, packet.calibrationID == current.calibrationID,
              packet.featureDigest == (try requirements.featureDigest()),
              Set(packet.features.map(\.id)) == Set(requirements.features.map(\.id)),
              old.streamID == now.streamID, old.generation == now.generation,
              old.index <= now.index, age.isFinite, age >= 0,
              (old.index != now.index || old == now),
              age <= requirements.validity.maxAgeSeconds,
              now.index - old.index <= requirements.validity.maxAgeFrames else {
            throw LabError.invalid("Observation packet identity or age mismatch")
        }
        if old == now {
            guard packet.captureConditions == current.captureConditions else { throw LabError.invalid("Same-frame capture facts disagree") }
            // Missing values in current-frame evidence belong to each response's
            // declared fallback policy. Missing-fact rejection below protects reuse.
            return packet
        }
        let policy = requirements.validity
        for axis in ConditionAxis.allCases {
            let a = packet.captureConditions[axis], b = current.captureConditions[axis]
            let tolerance = policy.sourceChangeTolerances.first { $0.axis == axis }
            // 未配置容差的已知条件要求完全一致；ISO 和曝光时长在 log₂ 坐标下比较。
            let required = requirements.sourceConditions.contains(axis) || tolerance != nil
            switch (a,b) {
            case (.some(let a), .some(let b)):
                let delta = abs((axis.logarithmic ? log2(a) : a) - (axis.logarithmic ? log2(b) : b))
                guard delta.isFinite, delta <= (tolerance?.maxCoordinateDelta ?? 0) else {
                    throw LabError.invalid("Delayed capture condition changed: \(axis.rawValue)")
                }
            case (.none,.none):
                if required && policy.rejectMissingSourceConditions { throw LabError.invalid("Missing required capture condition") }
            default:
                if policy.rejectMissingSourceConditions { throw LabError.invalid("Capture condition is missing from one frame") }
            }
        }
        return packet
    }
}
