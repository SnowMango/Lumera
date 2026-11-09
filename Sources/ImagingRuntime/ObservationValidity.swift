import ImagingCore

/// Runtime facade for the same pure packet rules used by offline sequence fitting.
public enum ObservationValidity {
    @discardableResult
    /// 校验并返回同一完整观测包；身份、年龄或拍摄事实不匹配时抛错，不修补旧包。
    public static func validate(_ packet: FrameObservations, current: FrameInputFacts, requirements: ObservationRequirements) throws -> FrameObservations {
        try ObservationPacketValidator.validate(packet, current: current, requirements: requirements)
    }
}
