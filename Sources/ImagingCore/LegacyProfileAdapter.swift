import Foundation

public enum LegacyProfileAdapter {
    /// Preserves schema-8 operations in the existing evaluator. LUT bytes remain
    /// caller-owned just as with Profile; the adapter invents no resource or weight.
    public static func adapt(_ profile: Profile) throws -> StyleModel {
        try profile.validate()
        var model = StyleModel(identity: .init(id: profile.id, name: profile.name))
        model.appearance.parameters = profile.parameters
        model.appearance.temporalPolicy = profile.temporalPolicy
        model.legacyProfile = profile
        model.observations.sourceConditions = ConditionAxis.allCases.filter { axis in profile.responses.contains { $0.axis == axis } }
        try model.validate()
        return model
    }
}
