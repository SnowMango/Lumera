import Foundation

/// Three Gaussian component sigmas in reference pixels. The average RGB kernel's
/// continuous second radial moment is exactly radius squared, before discretization.
package struct PreparedHalation: Sendable {
    package let sigmas: [Double]

    package init(radius: Double) {
        let meanSquaredScale = (1.0 * 0.25 + 1.2 + 0.8 * 4) / 3
        let sigma = radius / sqrt(2 * meanSquaredScale)
        sigmas = [0.5 * sigma, sigma, 2 * sigma]
    }
}
