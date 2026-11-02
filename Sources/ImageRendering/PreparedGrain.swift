import Foundation

/// Immutable calibration in reference pixels. The stationary covariance of an integrated
/// lattice is the overlap of its weights, averaged over the lattice phase.
package struct PreparedGrain: Sendable {
    package let fineSpacing, coarseSpacing, fineGain, coarseGain: Double

    package init(size: Double, roughness: Double) {
        // Solve the angular mean of the post-integration correlation at the requested lag.
        var lower = 0.02, upper = 2 * size
        for _ in 0..<28 {
            let spacing = (lower + upper) * 0.5
            let fine = roughness < 1 ? Self.correlation(spacing: spacing, lag: size) : 0
            let coarse = roughness > 0 ? Self.correlation(spacing: 2.5 * spacing, lag: size) : 0
            if fine * (1 - roughness) + coarse * roughness < 0.5 { lower = spacing }
            else { upper = spacing }
        }
        fineSpacing = (lower + upper) * 0.5
        coarseSpacing = fineSpacing * 2.5
        fineGain = sqrt(1 - roughness) / Self.overlap(spacing: fineSpacing, lag: 0)
        coarseGain = sqrt(roughness) / Self.overlap(spacing: coarseSpacing, lag: 0)
    }

    /// Parallelize wide output footprints before their area reduction. Each worker
    /// visits at most 128 cells per axis plus the spline's four-cell support.
    package func subdivision(scale: Double) -> Int {
        let spacing = fineGain == 0 ? coarseSpacing : fineSpacing
        let width = 1/(scale*spacing)
        var factor = 1
        // Valid geometry has a positive integer long edge; calibrated spacing
        // is at least 0.02. Even at 1x1, width <= 102400 and 1024 suffices.
        while factor < 1024 && width > 128*Double(factor) { factor *= 2 }
        return factor
    }

    private static func correlation(spacing: Double, lag: Double) -> Double {
        let zero = overlap(spacing: spacing, lag: 0)
        var sum = 0.0
        for index in 0..<12 {
            let angle = (Double(index) + 0.5) * .pi / 48
            sum += overlap(spacing: spacing, lag: lag * cos(angle))
                 * overlap(spacing: spacing, lag: lag * sin(angle))
        }
        return sum / (12 * zero * zero)
    }

    // Integral of the centered cubic B-spline, evaluated from its nearest tail.
    private static func cdf(_ x: Double) -> Double {
        let t = max(0, 2 - abs(x)), u = max(0, t - 1)
        let tail = (t*t*t*t - 4*u*u*u*u) / 24
        return x > 0 ? 1 - tail : tail
    }

    private static func overlap(spacing: Double, lag: Double) -> Double {
        // Unfold the sum over lattice sites and phase into one finite integral.
        // On each interval between spline knots both weights are quartic.
        // Five-point Gauss-Legendre is exact for their degree-eight product.
        let width = 1 / spacing, shift = lag / spacing
        let lower = -2 - width + shift, upper = 2.0
        guard lower < upper else { return 0 }
        var knots = [lower, upper]
        for k in -2...2 {
            for x in [Double(k), Double(k)-width, Double(k)+shift, Double(k)-width+shift]
                where x > lower && x < upper { knots.append(x) }
        }
        knots.sort()
        let nodes = [0.0, -0.5384693101056831, 0.5384693101056831, -0.906179845938664, 0.906179845938664]
        let weights = [0.5688888888888889, 0.4786286704993665, 0.4786286704993665, 0.2369268850561891, 0.2369268850561891]
        var sum = 0.0
        for (a,b) in zip(knots,knots.dropFirst()) where a < b {
            let half = (b-a)/2, center = (a+b)/2
            for i in nodes.indices {
                let x = center + half * nodes[i]
                sum += half * weights[i] * (cdf(x+width)-cdf(x)) * (cdf(x+width-shift)-cdf(x-shift))
            }
        }
        return sum * spacing * spacing
    }
}
