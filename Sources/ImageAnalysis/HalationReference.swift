import Foundation
import ImagingCore

/// Double precision oracle, calculated independently of uploaded Metal weights.
struct HalationKernelReference {
    let sigmas: [Double]
    static let channelMixtures = [[0.2,0.3,0.5], [0.3,0.5,0.2], [0.5,0.4,0.1]]

    var mixtures: [[Double]] { Self.channelMixtures }

    func weights(component: Int, pixelScale: Double) -> [Double] {
        let sigma = sigmas[component] * pixelScale
        let support = Int(ceil(4 * sigma))
        let weights = (-support...support).map { index -> Double in
            let distance = Double(abs(index)), k = sqrt(2) * sigma
            return 0.5 * (erfc((distance-0.5)/k) - erfc((distance+0.5)/k))
        }
        let sum = weights.reduce(0,+)
        return weights.map { $0 / sum }
    }

    /// Scalar bright-source luminance on a clamped image, before amount and tint.
    func residual(_ source: [Double], width: Int, height: Int, scaleX: Double, scaleY: Double) -> [SIMD3<Double>] {
        var spread = Array(repeating: SIMD3<Double>.zero, count: source.count)
        for component in sigmas.indices {
            func convolve(_ input: [Double], horizontal: Bool) -> [Double] {
                let size = horizontal ? width : height
                if size == 1 { return input }
                let weights = weights(component: component, pixelScale: horizontal ? scaleX : scaleY)
                let radius = weights.count / 2
                return input.indices.map { i in
                    let coordinate = horizontal ? i % width : i / width
                    let stride = horizontal ? 1 : width
                    var sum = 0.0
                    for j in weights.indices {
                        let neighbor = min(size-1,max(0,coordinate+j-radius))
                        sum += weights[j] * input[i+(neighbor-coordinate)*stride]
                    }
                    return sum
                }
            }
            let blurred = convolve(convolve(source,horizontal:true),horizontal:false)
            let gains = SIMD3(mixtures[0][component],mixtures[1][component],mixtures[2][component])
            for i in source.indices { spread[i] += gains * blurred[i] }
        }
        for i in source.indices {
            let difference = spread[i] - SIMD3(repeating:source[i])
            spread[i] = SIMD3(max(0,difference.x),max(0,difference.y),max(0,difference.z))
        }
        return spread
    }
}

enum HalationReference {
    static func kernel(radius: Double) throws -> HalationKernelReference {
        guard (0.1...32).contains(radius) else { throw LabError.invalid("光晕 RMS 半径超出范围") }
        let ratios = [0.5,1,2.0]
        let weights = HalationKernelReference.channelMixtures
        var moment = 0.0
        for channel in weights {
            for (weight, ratio) in zip(channel,ratios) { moment += 2 * weight * ratio * ratio / 3 }
        }
        return HalationKernelReference(sigmas:ratios.map { $0 * radius / sqrt(moment) })
    }
}
