import Foundation

public enum LegacyProfileAdapter {
    /// Preserves schema-8 operations in the existing evaluator. LUT bytes remain
    /// caller-owned just as with Profile; the adapter invents no resource or weight.
    public static func adapt(_ profile: Profile) throws -> CameraModel {
        try profile.validate()
        var model = CameraModel(identity: .init(id: profile.id, camera: "Legacy Profile", mode: profile.name))
        model.appearance.parameters = profile.parameters
        model.appearance.temporalPolicy = profile.temporalPolicy
        model.legacyProfile = profile
        model.observations.sourceConditions = ConditionAxis.allCases.filter { axis in profile.responses.contains { $0.axis == axis } }
        try model.validate()
        return model
    }
}
