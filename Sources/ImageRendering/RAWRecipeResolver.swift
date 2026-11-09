import Foundation
import ImagingCore

/// 合并系统默认值、配方和获准覆盖，再按后端能力校验设置。
enum RAWRecipeResolver {
    static func resolve(_ recipe: InputRecipe, overrides: [RAWOverride], supported: Set<RAWSetting.Key>, defaults: [RAWSetting]) throws -> [RAWSetting] {
        try recipe.validate()
        guard Set(overrides.map(\.key)).count == overrides.count else { throw LabError.invalid("Duplicate RAW overrides") }
        var settings = Dictionary(uniqueKeysWithValues: defaults.map { ($0.key, $0.value) })
        for value in recipe.rawSettings { try validate(value.key, value: value.value, supported: supported); settings[value.key] = value.value }
        for value in overrides {
            guard recipe.rawSettings.contains(where: { $0.key == value.key && $0.allowsUserOverride }) else { throw LabError.invalid("RAW override is not permitted by the author") }
            try validate(value.key, value: value.value, supported: supported); settings[value.key] = value.value
        }
        // 通用降噪值只在亮度和色彩两个后端设置均可用时展开。
        if let common = settings.removeValue(forKey: .noiseReduction) {
            guard !recipe.rawSettings.contains(where: { $0.key == .luminanceNoiseReduction || $0.key == .colorNoiseReduction }) else {
                throw LabError.invalid("Common and separate RAW noise controls overlap")
            }
            settings[.luminanceNoiseReduction] = common; settings[.colorNoiseReduction] = common
        }
        return settings.keys.sorted { $0.rawValue < $1.rawValue }.map { .init(key: $0, value: settings[$0]!) }
    }
    private static func validate(_ key: RAWSetting.Key, value: Double, supported: Set<RAWSetting.Key>) throws {
        guard supported.contains(key), value.isFinite, Float(value).isFinite else { throw LabError.unsupported("RAW backend does not support this setting/value: \(key.rawValue)") }
        if key == .noiseReduction {
            guard supported.contains(.luminanceNoiseReduction), supported.contains(.colorNoiseReduction) else {
                throw LabError.unsupported("Generic RAW noise control requires both backend components")
            }
        }
        let valid: Bool
        switch key {
        case .noiseReduction, .luminanceNoiseReduction, .colorNoiseReduction, .sharpness: valid = (0...1).contains(value)
        case .temperatureKelvin: valid = (2000...50000).contains(value)
        case .tint: valid = (-150...150).contains(value)
        case .exposureEV: valid = true
        }
        guard valid else { throw LabError.invalid("RAW setting is out of range: \(key.rawValue)") }
    }
}
