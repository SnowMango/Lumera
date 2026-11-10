import Foundation
import ImagingCore

/// Propagates conservative bounds in the order that the effect pipeline writes textures.
enum PrecisionSafety {
    static let halfStorageCeiling = 65504.0 / 1.02

    private struct Failure: Error {
        let stage: PrecisionAssessment.Stage
        let reason: String
    }

    static func require(_ assessment: PrecisionAssessment) throws {
        switch assessment {
        case .safe: return
        case .requiresInputRange:
            throw LabError.unsupported("Float16 requires trusted EDR input bounds; select Float32 explicitly")
        case .unsupported(let stage, let reason):
            if stage == .colorArithmetic { throw LabError.invalid(reason) }
            throw LabError.unsupported("Float16 cannot safely represent \(stage.rawValue): \(reason); select Float32 explicitly")
        }
    }

    static func assess(parameters: StyleParameters, color: PreparedColorTransform, correction: PreparedDeviceCorrection?,
                       lut: PreparedLUT?, blend: PreparedLUTBlend?, precision: RenderingPrecision,
                       request: RenderRequest, scale: Double, resizing: Bool, hasEffects: Bool,
                       preparedGrain: PreparedGrain?) -> PrecisionAssessment {
        let correctionGain = correction?.color.maximumGain ?? 1
        let combinedGain = max(correctionGain, color.maximumGain * (correction?.lut == nil ? correctionGain : 1))
        guard combinedGain.isFinite, combinedGain < Double(Float.greatestFiniteMagnitude) / 1024 else {
            return .unsupported(stage: .colorArithmetic, reason: "Combined color transform exceeds Float32 arithmetic range")
        }
        guard precision == .float16 else { return .safe }
        guard let input = request.inputValueBounds ?? (request.dynamicRange == .sdr ? NumericBounds(lower: 0, upper: 1) : nil) else {
            return .requiresInputRange
        }
        do {
            try validateHalf(input: input, parameters: parameters, color: color, correction: correction,
                             lut: lut, blend: blend, request: request, scale: scale, resizing: resizing,
                             hasEffects: hasEffects, preparedGrain: preparedGrain)
            return .safe
        } catch let failure as Failure {
            return .unsupported(stage: failure.stage, reason: failure.reason)
        } catch {
            return .unsupported(stage: .input, reason: error.localizedDescription)
        }
    }

    private static func validateHalf(input: NumericBounds, parameters p: StyleParameters, color: PreparedColorTransform,
                                     correction: PreparedDeviceCorrection?, lut: PreparedLUT?, blend: PreparedLUTBlend?,
                                     request: RenderRequest, scale: Double, resizing: Bool, hasEffects: Bool,
                                     preparedGrain: PreparedGrain?) throws {
        let extended = request.dynamicRange == .edr
        let previewGlow = request.previewGlow
        let arithmeticMargin = 1.0001
        func stored(_ value: Double, _ stage: PrecisionAssessment.Stage) throws -> Double {
            guard value.isFinite, value >= 0, value <= halfStorageCeiling else {
                throw Failure(stage: stage, reason: "Conservative bound exceeds the Float16 storage margin")
            }
            return value * 1.001 + Double(Float16.leastNonzeroMagnitude)
        }
        func checkFloat(_ value: Double, _ stage: PrecisionAssessment.Stage) throws {
            guard value.isFinite, value < Double(Float.greatestFiniteMagnitude) / 16 else {
                throw Failure(stage: stage, reason: "Conservative bound exceeds Float32 intermediate arithmetic")
            }
        }
        func transform(_ value: Double, _ color: PreparedColorTransform, _ stage: PrecisionAssessment.Stage) throws -> Double {
            let linear = decode(value) * gain(color) * arithmeticMargin
            let exposed = decode(value) * abs(Double(Float(color.exposureMultiplier))) * arithmeticMargin
            try checkFloat(max(linear, exposed), stage)
            return try stored(encode(linear) * arithmeticMargin, stage)
        }
        func sample(_ lut: PreparedLUT, _ range: NumericBounds, _ stage: PrecisionAssessment.Stage) throws -> Double {
            guard let value = lut.rangeProof.magnitude(input: range, extrapolates: lut.boundaryPolicy.extrapolates(in: request.dynamicRange)) else {
                throw Failure(stage: stage, reason: "Boundary-cell interpolation exceeds Float32 intermediate arithmetic")
            }
            return value
        }
        func symmetric(_ value: Double) -> NumericBounds { NumericBounds(lower: -value, upper: value) }

        var b = try stored(max(abs(input.lower), abs(input.upper)), .input)
        guard hasEffects || resizing else { return }
        // The texture can contain the original Float32 endpoints or their nearest half
        // representations (including a Float32 conversion before the half upload).
        var range = NumericBounds(lower: min(input.lower, Double(Float(input.lower)), Double(Float16(Float(input.lower)))),
                                  upper: max(input.upper, Double(Float(input.upper)), Double(Float16(Float(input.upper)))))
        if let correction {
            if correction.colorIsActive {
                b = try transform(b, correction.color, .correctionColor)
                range = symmetric(b)
            }
            if let table = correction.lut {
                b = try stored(sample(table, range, .correctionLUT), .correctionLUT)
                range = symmetric(b)
            }
        }
        if resizing {
            let linear = try stored(decode(b) * arithmeticMargin, .resize)
            let scaled = try stored(linear * arithmeticMargin, .resize)
            b = try stored(encode(scaled) * arithmeticMargin, .resize)
            range = symmetric(b)
        }
        if p.color.isActive {
            b = try transform(b, color, .creativeColor)
            range = symmetric(b)
        }
        if let blend {
            var total = 0.0
            for (table, coefficient) in zip(blend.luts, blend.weights) where coefficient > 0 {
                total += Double(coefficient) * (try sample(table, range, .creativeLUT))
            }
            // Float32 coefficients match the shader. Only the final sum is stored in half.
            try checkFloat(total, .creativeLUT)
            b = try stored(total * arithmeticMargin, .creativeLUT)
        } else if let lut {
            b = try stored(sample(lut, range, .creativeLUT), .creativeLUT)
        }
        if p.tone.isActive { b = try stored((extended ? b + 1 : 1) * arithmeticMargin, .tone) }

        // Each separable pass writes half before the next pass reads it.
        var sigma = 0.0
        if p.detail.isActive { sigma = max(sigma, p.detail.fineSigma, p.detail.midSigma, p.detail.sharpenSigma) }
        if p.softening.isActive { sigma = max(sigma, p.softening.sigma) }
        if previewGlow && p.glow.isActive { sigma = max(sigma, p.glow.nearSigma, p.glow.farSigma) }
        if previewGlow && p.halation.isActive { sigma = max(sigma, p.halation.radius * 4) }
        if p.noise.isActive { sigma = max(sigma, p.noise.lumaSigma, p.noise.chromaSigma) }
        let samples = 2 * ceil(4 * sigma * scale) + 1
        let error = samples * Double(Float.ulpOfOne) / 2
        guard error < 0.25 else { throw Failure(stage: .spatialAccumulation, reason: "Spatial kernel exceeds the Float32 accumulation bound") }
        let axisMargin = arithmeticMargin / pow(1 - error, 2)
        func blurred(_ value: Double, _ stage: PrecisionAssessment.Stage, normalization: Double = 1) throws -> Double {
            let horizontal = try stored(value * normalization * axisMargin, stage)
            return try stored(horizontal * normalization * axisMargin, stage)
        }

        if p.detail.isActive {
            let lowpass = try blurred(b, .detail)
            let fine = Double(Float(p.detail.fineGain)), mid = Double(Float(p.detail.midGain))
            let sourceTerm = b * (1 + abs(fine - 1))
            let blurTerm = lowpass * (abs(mid - fine) + abs(1 - mid))
            b = try stored((sourceTerm + blurTerm) * arithmeticMargin, .detail)
            if p.detail.sharpenAmount > 0 {
                _ = try blurred(b, .detail)
                b = try stored((b + p.detail.maxAdjustment) * arithmeticMargin, .detail)
            }
        }
        b = try stored(decode(b) * arithmeticMargin, .linearOpticalInput)
        if p.softening.isActive {
            let base = request.softeningScale == .full ? b : try stored(b * arithmeticMargin, .softening)
            let lowpass = try blurred(base, .softening)
            b = try stored(max(b, lowpass) * arithmeticMargin, .softening)
        }
        if p.vignette.enabled && p.vignette.amountEV > 0 {
            b = try stored(b * arithmeticMargin, .vignette)
        }
        if previewGlow && p.glow.isActive {
            let highlights = try stored(b * arithmeticMargin, .glow)
            let spread = try blurred(highlights, .glow)
            b = try stored((b + p.glow.amount * (max(b, highlights) + spread)) * arithmeticMargin, .glow)
        }
        if previewGlow && p.halation.isActive {
            let highlights = try stored(b * arithmeticMargin, .halation)
            let spread = try blurred(highlights, .halation)
            let tint = max(p.halation.red, p.halation.green, p.halation.blue)
            b = try stored((b + p.halation.amount * tint * (max(b, highlights) + spread)) * arithmeticMargin, .halation)
        }
        b = encode(b) * arithmeticMargin
        if p.noise.isActive {
            // L1/L2 <= sqrt(N) on each axis. Include raw field and each half write.
            let n = 2 * ceil(3 * max(p.noise.lumaSigma, p.noise.chromaSigma) * scale) + 1
            let raw = try stored(6, .noise)
            let field = try blurred(raw, .noise, normalization: sqrt(n))
            let correlation = abs(p.noise.chromaCorrelation) + sqrt(1 - p.noise.chromaCorrelation * p.noise.chromaCorrelation)
            let chroma = max(1.5748 * correlation, 0.187324 + 0.468124 * correlation, 1.8556)
            b = (b + 0.1 * field * (1 + p.noise.chromaRatio * chroma)) * arithmeticMargin
        }
        b = try stored(extended ? b : 1, .finish)
        if p.grain.isActive {
            guard let grain = preparedGrain else { throw Failure(stage: .grain, reason: "Missing prepared grain geometry") }
            // Bound lattice values and cancellation in the Float32 CDF differences.
            let width = 1 / (scale * max(grain.fineSpacing, grain.coarseSpacing))
            let integrationMargin = pow(1 + 4e-6 * ceil(width + 4) / width, 2) * 1.01
            let raw = try stored(1.831 * (grain.fineGain + grain.coarseGain) * integrationMargin, .grain)
            let factor = Double(grain.subdivision(scale: scale))
            try checkFloat(factor * factor * raw, .grain)
            _ = try stored((b + p.grain.amount * raw * (1 + 1.8556 * p.grain.chroma)) * arithmeticMargin, .grain)
        }
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
}
