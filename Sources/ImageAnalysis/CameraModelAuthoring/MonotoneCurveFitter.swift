import Foundation
import ImagingCore

/// 在 [0, 1] 域拟合单调数值色调曲线，输出曲线和可辨识性相关诊断。
public enum MonotoneCurveFitter {
    public struct Sample: Equatable, Sendable {
        public var x: Double, y: Double, weight: Double
        public init(x: Double, y: Double, weight: Double = 1) { self.x = x; self.y = y; self.weight = weight }
    }
    public struct Diagnostics: Equatable, Sendable {
        public let iterations: Int
        public let converged: Bool
        public let weightedRMSE: Double
        /// 归一化加权残差平方和与正则化二阶差分平方和，各取一半。
        public let objective: Double
        public let measuredRange: ClosedRange<Double>
        /// 样本覆盖外的平滑延拓区间，由正则约束推得。
        public let unmeasuredIntervals: [ClosedRange<Double>]
    }
    public struct Result: Equatable, Sendable {
        public let curve: ResponseCurve
        public let diagnostics: Diagnostics
    }

    /// 拟合 32 个均匀节点及其线性插值。正则项惩罚固定网格的二阶差分，不受样本总权重影响。
    /// 正则为零时，观测必须能辨识全部节点。
    public static func fit(samples: [Sample], regularization: Double = 1e-3,
                           maxIterations: Int = 100, tolerance: Double = 1e-6) throws -> Result {
        guard regularization.isFinite, regularization >= 0, maxIterations > 0,
              maxIterations <= 1_000_000, tolerance.isFinite, tolerance > 0, tolerance < 1,
              samples.count >= 2, samples.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.weight.isFinite &&
                  (0...1).contains($0.x) && (0...1).contains($0.y) && $0.weight > 0 }) else {
            throw LabError.invalid("Invalid monotone curve samples or solver options")
        }
        let sorted = samples.sorted { a, b in a.x == b.x ? (a.y == b.y ? a.weight < b.weight : a.y < b.y) : a.x < b.x }
        let lower = sorted.first!.x, upper = sorted.last!.x
        guard upper - lower > 1e-9 else { throw LabError.invalid("Curve observations do not identify an input interval") }
        // 先按最大权重缩放再求和，避免有限大权重使累加溢出。
        let maxWeight = sorted.map(\.weight).max()!
        let scaledTotal = sorted.reduce(0) { $0 + $1.weight / maxWeight }
        let normalized = sorted.map { Sample(x: $0.x, y: $0.y, weight: ($0.weight / maxWeight) / scaledTotal) }
        guard normalized.allSatisfy({ $0.weight > 0 }) else { throw LabError.invalid("Sample weight dynamic range is numerically unidentifiable") }
        let count = 32
        var h = Array(repeating: Array(repeating: 0.0, count: count), count: count)
        var rhs = Array(repeating: 0.0, count: count)
        func basis(_ x: Double) -> (Int, Double) {
            let position = x * 31, left = min(30, Int(position))
            return (left, position - Double(left))
        }
        for sample in normalized {
            let (i, t) = basis(sample.x)
            let coefficients = [1 - t, t]
            for a in 0..<2 {
                rhs[i + a] += sample.weight * coefficients[a] * sample.y
                for b in 0..<2 { h[i + a][i + b] += sample.weight * coefficients[a] * coefficients[b] }
            }
        }
        for i in 0..<30 {
            let coefficients = [1.0, -2.0, 1.0]
            for a in 0..<3 { for b in 0..<3 { h[i + a][i + b] += regularization * coefficients[a] * coefficients[b] } }
        }
        guard h.flatMap({ $0 }).allSatisfy(\.isFinite) else { throw LabError.invalid("Curve objective overflow") }
        // Positive definiteness establishes identifiability, including the two
        // affine nullspace dimensions of the curvature prior.
        var factor = Array(repeating: Array(repeating: 0.0, count: count), count: count)
        let scale = (0..<count).map { h[$0][$0] }.max()!
        for i in 0..<count {
            for j in 0...i {
                var value = h[i][j]
                for k in 0..<j { value -= factor[i][k] * factor[j][k] }
                if i == j {
                    guard value.isFinite, value > scale * 1e-12 else { throw LabError.invalid("Curve evidence and regularization are numerically unidentifiable") }
                    factor[i][j] = sqrt(value)
                } else { factor[i][j] = value / factor[j][j] }
            }
        }
        let metric = (0..<count).map { h[$0][$0] }
        // Gershgorin upper bound for the metric-scaled Hessian yields a safe step.
        let lipschitz = (0..<count).map { i in
            (0..<count).reduce(0.0) { $0 + abs(h[i][$1]) / sqrt(metric[i] * metric[$1]) }
        }.max()!
        guard lipschitz.isFinite, lipschitz > 0 else { throw LabError.invalid("Invalid curve optimization scale") }
        let meanX = normalized.reduce(0) { $0 + $1.weight * $1.x }
        let meanY = normalized.reduce(0) { $0 + $1.weight * $1.y }
        let variance = normalized.reduce(0) { $0 + $1.weight * pow($1.x - meanX, 2) }
        let covariance = normalized.reduce(0) { $0 + $1.weight * ($1.x - meanX) * ($1.y - meanY) }
        guard variance > 1e-18 else { throw LabError.invalid("Insufficient weighted input variation") }
        let slope = max(0, covariance / variance)
        var values = (0..<count).map { min(1, max(0, meanY + slope * (Double($0) / 31 - meanX))) }
        var converged = false, iterations = 0
        for iteration in 1...maxIterations {
            let candidate = (0..<count).map { i -> Double in
                let gradient = (0..<count).reduce(-rhs[i]) { $0 + h[i][$1] * values[$1] }
                return values[i] - gradient / (lipschitz * metric[i])
            }
            let next = project(candidate, weights: metric)
            let movement = zip(values, next).map { abs($0 - $1) }.max()!
            values = next; iterations = iteration
            if movement <= tolerance { converged = true; break }
        }
        let curve = ResponseCurve(knots: values.enumerated().map { .init(x: Double($0.offset) / 31, y: $0.element) }, interpolation: .linear)
        try curve.validate(kind: .tone)
        let residual = normalized.reduce(0) { $0 + $1.weight * pow(curve.value(at: $1.x) - $1.y, 2) }
        let curvature = (0..<30).reduce(0.0) { $0 + pow(values[$1] - 2 * values[$1 + 1] + values[$1 + 2], 2) }
        var unmeasured: [ClosedRange<Double>] = []
        if lower > 0 { unmeasured.append(0...lower) }
        if upper < 1 { unmeasured.append(upper...1) }
        return .init(curve: curve, diagnostics: .init(iterations: iterations, converged: converged,
            weightedRMSE: sqrt(residual), objective: (residual + regularization * curvature) / 2,
            measuredRange: lower...upper, unmeasuredIntervals: unmeasured))
    }

    /// Weighted pool-adjacent-violators projection onto 0 <= y[0] <= ... <= y[n-1] <= 1.
    private static func project(_ values: [Double], weights: [Double]) -> [Double] {
        struct Block { var first: Int; var last: Int; var weight: Double; var mean: Double }
        var blocks: [Block] = []
        for i in values.indices {
            blocks.append(.init(first: i, last: i, weight: weights[i], mean: values[i]))
            while blocks.count > 1 && blocks[blocks.count - 2].mean > blocks.last!.mean {
                let right = blocks.removeLast(), left = blocks.removeLast()
                let weight = left.weight + right.weight
                blocks.append(.init(first: left.first, last: right.last, weight: weight,
                    mean: left.mean * (left.weight / weight) + right.mean * (right.weight / weight)))
            }
        }
        var result = values
        for block in blocks { for i in block.first...block.last { result[i] = min(1, max(0, block.mean)) } }
        return result
    }
}
