import Foundation
import ImagingCore

/// Bounds for the boundary-cell continuation of the Float32 samples uploaded to Metal.
struct LUTRangeProof {
    private let intervals: Double
    // Bit masks index the finite differences in x, y and z. Mask zero is the sample maximum.
    private let differences: [Double]
    private let varyingAxes: SIMD3<Int>
    let isExactIdentity: Bool

    init(_ cube: CubeLUT) {
        let n = cube.size
        intervals = Double(n - 1)
        func sample(_ r: Int, _ g: Int, _ b: Int) -> SIMD3<Double> {
            let i = ((b * n + g) * n + r) * 4
            return SIMD3(Double(cube.rgba[i]), Double(cube.rgba[i + 1]), Double(cube.rgba[i + 2]))
        }
        func difference(_ r: Int, _ g: Int, _ b: Int, axes: Int) -> SIMD3<Double> {
            switch axes {
            case 0: return sample(r, g, b)
            case 1: return sample(r + 1, g, b) - sample(r, g, b)
            case 2...3: return difference(r, g + 1, b, axes: axes - 2) - difference(r, g, b, axes: axes - 2)
            default: return difference(r, g, b + 1, axes: axes - 4) - difference(r, g, b, axes: axes - 4)
            }
        }
        var maxima = [Double](repeating: 0, count: 8)
        var identity = true
        var varying = SIMD3<Int>(repeating: 0)
        func recordVariation(_ axis: Int, _ a: SIMD3<Double>, _ b: SIMD3<Double>) {
            for channel in 0..<3 where a[channel] != b[channel] { varying[channel] |= axis }
        }
        let vertices = Array(0..<n), boundaryCells = n == 2 ? [0] : [0, n - 2]
        for axes in maxima.indices {
            let reds = axes & 1 == 0 ? vertices : boundaryCells
            let greens = axes & 2 == 0 ? vertices : boundaryCells
            let blues = axes & 4 == 0 ? vertices : boundaryCells
            for b in blues {
                for g in greens {
                    for r in reds {
                        let d = difference(r, g, b, axes: axes)
                        maxima[axes] = max(maxima[axes], abs(d.x), abs(d.y), abs(d.z))
                        if axes == 0 {
                            if identity {
                                let denominator = Float(n - 1)
                                identity = d == SIMD3(Double(Float(r) / denominator), Double(Float(g) / denominator), Double(Float(b) / denominator))
                            }
                            if r > 0 { recordVariation(1, d, sample(0, g, b)) }
                            if g > 0 { recordVariation(2, d, sample(r, 0, b)) }
                            if b > 0 { recordVariation(4, d, sample(r, g, 0)) }
                        }
                    }
                }
            }
        }
        // The recursive differences use at most seven Double subtractions.
        // Pad their absolute bounds to account for cancellation in the host calculation.
        differences = maxima.enumerated().map { mask, maximum in
            maximum + (mask == 0 ? 0 : 16 * Double.ulpOfOne * maxima[0])
        }
        varyingAxes = varying
        isExactIdentity = identity
    }

    /// Returns nil if Float32 coordinates or interpolation intermediates cannot be bounded.
    func magnitude(input: NumericBounds, extrapolates: Bool) -> Double? {
        let u = Double(Float.ulpOfOne) / 2
        let coord = intervals * max(abs(input.lower), abs(input.upper), 1)
        let excursion = max(-input.lower, input.upper - 1, 0)
        // Include coordinate multiply/subtract rounding. Index clamping precedes conversion.
        let distance = extrapolates ? intervals * excursion + 4 * u * (coord + intervals) : 0
        let amplification = 1 + 2 * distance
        let floatCeiling = Double(Float.greatestFiniteMagnitude) / 16
        guard !extrapolates || coord < floatCeiling else { return nil }

        var exact = differences[0]
        var error = SIMD3<Double>(repeating: 0)
        for axis in [1, 2, 4] {
            // A mix may be computed as a + (b - a) * t or as weighted endpoint
            // terms. Bound either sequence, including intermediate values before cancellation.
            let intermediate = 4 * amplification * (exact + max(error.x, error.y, error.z))
            guard intermediate < floatCeiling else { return nil }
            let localError = 8 * u * intermediate + 8 * Double(Float.leastNormalMagnitude)
            for channel in 0..<3 {
                // Constant slices have identical incoming errors for this channel.
                // Only the local mix can introduce new error on an invariant axis.
                let multiplier = varyingAxes[channel] & axis == 0 ? 1 : amplification
                error[channel] = multiplier * error[channel] + localError
            }
            // Expand about the clamped coordinates. Mixed derivatives in the
            // remaining axes are convex interpolations of their vertex differences.
            // Only dimensions already sampled by the shader contribute at this step.
            for mask in axis..<(2 * axis) {
                exact += differences[mask] * pow(distance, Double(mask.nonzeroBitCount))
            }
        }
        return (exact + max(error.x, error.y, error.z)) * (1 + 16 * Double.ulpOfOne)
    }
}
