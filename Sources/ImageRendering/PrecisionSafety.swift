import Foundation
import ImagingCore

/// 按管线阶段传播保守的数值上界，判定半精度存储是否安全。调用方显式决定精度。
enum PrecisionSafety {
    static func validate(inputBounds: ClosedRange<Float>, controls: ResolvedControls,
                         resources: ModelResourceSet, precision: ExecutionPrecision, dynamicRange: RenderDynamicRange,
                         scale: Double, resizing: Bool, preparedGrain: PreparedGrain? = nil) throws {
        try controls.parameters.validate(resolved: true)
        try ResourceWeight.validate(controls.lutWeights)
        var inputColor = ColorResponse()
        inputColor.exposureEV = controls.inputExposureEV
        if let wb = controls.inputWhiteBalance { inputColor.whiteBalance = wb }
        let inputTransform = try ColorTransform.prepare(inputColor)
        var bound = max(abs(Double(inputBounds.lowerBound)), abs(Double(inputBounds.upperBound)))
        guard bound.isFinite else { throw failure("invalid source range") }
        if precision == .float16, bound > 65504 / 1.02 { throw failure("original source storage") }
        if inputColor.isActive {
            let linear = decode(bound) * gain(inputTransform)
            guard linear.isFinite, linear < Double(Float.greatestFiniteMagnitude) / 16 else { throw failure("input edit arithmetic") }
            bound = encode(linear)
            if precision == .float16, bound > 65504 / 1.02 { throw failure("input edit storage") }
        }
        let assets = try controls.lutWeights.map { weight -> LUTSafety in
            guard let asset = resources.luts[weight.resourceID] else { throw LabError.invalid("Missing LUT resource") }
            return try LUTSafety(asset, range: dynamicRange)
        }
        if precision == .float16, assets.contains(where: { $0.extrapolates && !$0.identity }) {
            throw failure("non-identity LUT extrapolation")
        }
        // This resource-based overload is for preparation. Frame encoding uses cached LUT metadata below.
        try validate(bound: bound, parameters: controls.parameters, color: ColorTransform.prepare(controls.parameters.color),
                     correction: nil, lut: assets.isEmpty ? nil : .init(identity: true, extrapolates: assets.contains(where: \.extrapolates)),
                     precision: precision, extended: dynamicRange == .edr, scale: scale, resizing: resizing,
                     preparedGrain: preparedGrain)
    }
    struct LUTSafety {
        let identity: Bool
        let extrapolates: Bool
        init(identity: Bool, extrapolates: Bool) { self.identity = identity; self.extrapolates = extrapolates }
        init(_ asset: LUTAsset, range: RenderDynamicRange) throws {
            let cube = try asset.decodedCube()
            var identity = true
            for b in 0..<cube.size { for g in 0..<cube.size { for r in 0..<cube.size {
                let i = ((b * cube.size + g) * cube.size + r) * 4
                if cube.rgba[i] != Float(r) / Float(cube.size - 1) || cube.rgba[i + 1] != Float(g) / Float(cube.size - 1) || cube.rgba[i + 2] != Float(b) / Float(cube.size - 1) { identity = false }
            } } }
            self.identity = identity; self.extrapolates = asset.boundaryPolicy.extrapolates(in: range)
        }
    }
    static func validate(bound initial: Double, parameters p: StyleParameters, color: PreparedColorTransform,
                         correction: PreparedDeviceCorrection?, lut: LUTSafety?, precision: ExecutionPrecision,
                         extended: Bool, scale: Double, resizing: Bool, previewGlow: Bool = true, preparedGrain: PreparedGrain?) throws {
        guard initial.isFinite, initial >= 0, scale.isFinite, scale > 0 else { throw failure("Unknown or invalid input range") }
        // 此处逐阶段传播的上界用于半精度存储校验。
        guard precision == .float16 else { return }
        // 最大有限半精度值预留余量，每次存储继续计入舍入与最小非零量级。
        let ceiling = 65504.0 / 1.02
        func stored(_ value: Double, _ stage: String) throws -> Double {
            guard value.isFinite, value >= 0, value <= ceiling else { throw failure(stage) }
            return value * 1.001 + Double(Float16.leastNonzeroMagnitude)
        }
        func floatMath(_ value: Double, _ stage: String) throws -> Double {
            guard value.isFinite, value < Double(Float.greatestFiniteMagnitude) / 16 else { throw failure(stage) }; return value
        }
        func transform(_ value: Double, _ color: PreparedColorTransform) throws -> Double {
            let linear = try floatMath(decode(value) * gain(color), "color transform")
            return try stored(encode(linear), "encoded color")
        }
        func table(_ value: Double, _ info: LUTSafety?) throws -> Double {
            guard let info else { return value }
            if info.extrapolates {
                guard info.identity else { throw failure("Unbounded non-identity LUT extrapolation") }
                return try stored(max(value, 1), "identity or bounded LUT mixture")
            }
            return try stored(1, "bounded LUT")
        }
        // 按最大空间核估算 Float32 累加误差，两轴分别累计。
        var sigma = 0.0
        if p.detail.isActive { sigma = max(sigma, p.detail.fineSigma, p.detail.midSigma, p.detail.sharpenSigma) }
        if p.softening.isActive { sigma = max(sigma, p.softening.sigma) }
        if previewGlow && p.glow.isActive { sigma = max(sigma, p.glow.nearSigma, p.glow.farSigma) }
        if previewGlow && p.halation.isActive { sigma = max(sigma, p.halation.radius * 4) }
        if p.noise.isActive { sigma = max(sigma, p.noise.lumaSigma, p.noise.chromaSigma) }
        let samples = 2 * ceil(4 * sigma * scale) + 1
        let error = samples * Double(Float.ulpOfOne) / 2
        guard error < 0.25 else { throw failure("Spatial accumulation bound") }
        let blurFactor = pow(1 / (1 - error), 2) * 1.002
        var b = try stored(initial, "input")
        if let correction {
            if correction.colorIsActive { b = try transform(b, correction.color) }
            if correction.lutTexture != nil {
                b = try table(b, .init(identity: correction.lutIsExactIdentity,
                                      extrapolates: correction.lutBoundaryPolicy.extrapolates(in: extended ? .edr : .sdr)))
            }
        }
        if resizing { b = try stored(encode(stored(decode(b), "resize linear")), "resize encoded") }
        if p.color.isActive { b = try transform(b, color) }
        b = try table(b, lut)
        if p.tone.isActive { b = try stored(extended ? b + 1 : 1, "tone") }
        if p.detail.isActive {
            let blurred = try stored(b * blurFactor, "detail blur")
            let sourceTerm = b * (1 + abs(p.detail.fineGain - 1))
            let blurTerm = blurred * (abs(p.detail.midGain - p.detail.fineGain) + abs(1 - p.detail.midGain))
            b = try stored(sourceTerm + blurTerm, "detail")
            if p.detail.sharpenAmount > 0 {
                _ = try stored(b * blurFactor, "sharpen blur")
                b = try stored(b + p.detail.maxAdjustment, "sharpen")
            }
        }
        b = try stored(decode(b), "linear optical input")
        if p.softening.isActive { b = try stored(b * blurFactor, "softening") }
        if previewGlow && p.glow.isActive {
            let spread = try stored(b * blurFactor, "glow spread")
            b = try stored(b + p.glow.amount * (b + spread), "glow")
        }
        if previewGlow && p.halation.isActive {
            let spread = try stored(b * blurFactor, "halation spread")
            b = try stored(b + p.halation.amount * max(p.halation.red, p.halation.green, p.halation.blue) * (b + spread), "halation")
        }
        b = try stored(encode(b), "encoded finish")
        if p.noise.isActive {
            // L1/L2 <= sqrt(N) per axis. Include raw RGB and alpha storage before amplitude.
            let n = 2 * ceil(3 * max(p.noise.lumaSigma, p.noise.chromaSigma) * scale) + 1
            let field = try stored(6 * n * blurFactor, "noise field")
            let correlation = abs(p.noise.chromaCorrelation) + sqrt(1 - p.noise.chromaCorrelation * p.noise.chromaCorrelation)
            let chroma = max(1.5748 * correlation, 0.187324 + 0.468124 * correlation, 1.8556)
            b = try stored(b + 0.1 * field * (1 + p.noise.chromaRatio * chroma), "noise finish")
        }
        if p.grain.isActive {
            guard let grain = preparedGrain else { throw LabError.invalid("Grain safety requires the prepared execution geometry") }
            // Bound lattice values and cancellation in the Float32 CDF differences.
            let width = 1 / (scale * max(grain.fineSpacing, grain.coarseSpacing))
            let integrationMargin = pow(1 + 4e-6 * ceil(width + 4) / width, 2) * 1.01
            let raw = try stored(1.831 * (grain.fineGain + grain.coarseGain) * integrationMargin, "grain subpixels")
            let factor = Double(grain.subdivision(scale: scale))
            _ = try floatMath(factor * factor * raw, "grain reduction")
            b = try stored(b + p.grain.amount * raw * (1 + 1.8556 * p.grain.chroma), "grain finish")
        }
        _ = b
    }
    private static func gain(_ color: PreparedColorTransform) -> Double {
        let matrix = color.matrix.map { abs(Double(Float($0))) }
        var maximum = 0.0
        for row in 0..<3 {
            let a = matrix[row * 3], b = matrix[row * 3 + 1], c = matrix[row * 3 + 2]
            maximum = max(maximum, a + b + c)
        }
        return maximum * abs(Double(Float(color.exposureMultiplier))) * 1.00001
    }
    private static func decode(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
    private static func encode(_ value: Double) -> Double { value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055 }
    private static func failure(_ stage: String) -> LabError { .unsupported("Float16 cannot safely represent \(stage); select Float32 explicitly") }
}
