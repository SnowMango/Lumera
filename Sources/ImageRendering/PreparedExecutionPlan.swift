import Foundation
import ImagingCore

/// 固定快照和动态帧共用的执行数据缓存。锁保护条目与计数，取出的不可变数据可跨条目替换使用。
final class PreparedExecutionPlan: @unchecked Sendable {
    private let lock = NSLock()
    private let baseColor: (ColorResponse, PreparedColorTransform)
    private var lastCurves: (StyleParameters, PreparedResponseCurves)?
    private var lastColor: (ColorResponse, PreparedColorTransform)?
    private var lastGrain: (size: Double, roughness: Double, value: PreparedGrain)?
    private var lastHalation: (radius: Double, value: PreparedHalation)?
    private var halationPreparations = 0
    private var colorPreparations = 1
    private var grainPreparations = 0

    init(parameters: StyleParameters, color: PreparedColorTransform) {
        self.baseColor = (parameters.color, color)
        if parameters.halation.isActive {
            _ = halation(for: parameters.halation)
        }
        if parameters.grain.isActive {
            _ = grain(for: parameters.grain)
        }
    }

    func curves(for parameters: StyleParameters) -> PreparedResponseCurves {
        lock.lock(); defer { lock.unlock() }
        if let cached = lastCurves, cached.0.tone.curve == parameters.tone.curve,
           cached.0.noise.curve == parameters.noise.curve, cached.0.grain.luminanceCurve == parameters.grain.luminanceCurve { return cached.1 }
        let value = PreparedResponseCurves(parameters); lastCurves = (parameters, value); return value
    }

    func color(for parameters: ColorResponse) throws -> PreparedColorTransform {
        if parameters == baseColor.0 { return baseColor.1 }
        lock.lock()
        defer { lock.unlock() }
        if let lastColor, lastColor.0 == parameters { return lastColor.1 }
        let value = try ColorTransform.prepare(parameters)
        lastColor = (parameters, value)
        colorPreparations += 1
        return value
    }

    func grain(for parameters: FilmGrain) -> PreparedGrain {
        lock.lock()
        defer { lock.unlock() }
        if let cached = lastGrain, cached.size == parameters.size, cached.roughness == parameters.roughness {
            return cached.value
        }
        let value = PreparedGrain(size: parameters.size, roughness: parameters.roughness)
        lastGrain = (parameters.size, parameters.roughness, value)
        grainPreparations += 1
        return value
    }

    func halation(for parameters: Halation) -> PreparedHalation {
        lock.lock()
        defer { lock.unlock() }
        if let cached = lastHalation, cached.radius == parameters.radius {
            return cached.value
        }
        let value = PreparedHalation(radius: parameters.radius)
        lastHalation = (parameters.radius, value)
        halationPreparations += 1
        return value
    }

    var counts: (colors: Int, grains: Int, halations: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (colorPreparations, grainPreparations, halationPreparations)
    }
}
