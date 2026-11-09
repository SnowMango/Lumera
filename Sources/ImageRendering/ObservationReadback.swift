import Foundation
import Metal
import ImagingCore

/// 与原命令缓冲区绑定的小型统计结果。GPU 统计须在该命令成功完成后读取。
public struct ObservationReadback {
    private let observation: FrameObservations
    private let features: [FeatureSpecification]
    private let buffer: MTLBuffer?
    private let command: MTLCommandBuffer?
    /// 面积采样网格尺寸，仅含拍摄元数据时两维均为零。
    public let sampleWidth: Int, sampleHeight: Int
    let reductionPartitionCount: Int
    public var readbackBytes: Int { buffer?.length ?? 0 }
    init(observation: FrameObservations, features: [FeatureSpecification], buffer: MTLBuffer?, command: MTLCommandBuffer?, width: Int, height: Int, partitions: Int) {
        self.observation = observation; self.features = features; self.buffer = buffer; self.command = command
        sampleWidth = width; sampleHeight = height; reductionPartitionCount = partitions
    }
    private func values() throws -> UnsafePointer<Float>? {
        guard let buffer else { return nil }
        guard let command, command.status == .completed, command.error == nil else { throw LabError.invalid("Observation readback requires successful GPU completion") }
        let values = buffer.contents().bindMemory(to: Float.self, capacity: buffer.length / 4)
        guard values[261] == 0, (0..<(buffer.length / 4)).allSatisfy({ values[$0].isFinite }) else { throw LabError.invalid("Feature sample contains nonfinite values") }
        return UnsafePointer(values)
    }
    /// 线性亮度严格小于 0 或大于 1 的面积样本比例，与包含端点的亮暗阈值统计分别计算。
    public func clippingFractions() throws -> (belowZero: Double, aboveOne: Double) {
        guard let v = try values() else { return (0, 0) }
        return (Double(v[259]), Double(v[260]))
    }
    /// 解析捕获事实与特征值。亮度分位值取命中直方图区间的中心。
    public func resolve() throws -> FrameObservations {
        var result = observation
        guard let v = try values() else { return result }
        let count = sampleWidth * sampleHeight
        result.features = features.enumerated().map { index, feature in
            let value: Double
            switch feature.statistic {
            case .meanRed: value = Double(v[256])
            case .meanGreen: value = Double(v[257])
            case .meanBlue: value = Double(v[258])
            case .fractionBelow, .fractionAbove: value = Double(v[262 + index])
            case .luminanceQuantile(let fraction):
                let target = max(1, Int(ceil(fraction * Double(count))))
                var cumulative = 0, bin = 0
                for i in 0..<256 { cumulative += Int(v[i]); bin = i; if cumulative >= target { break } }
                value = (Double(bin) + 0.5) / 256
            }
            return FeatureValue(id: feature.id, value: value)
        }
        try result.validate()
        return result
    }
}
