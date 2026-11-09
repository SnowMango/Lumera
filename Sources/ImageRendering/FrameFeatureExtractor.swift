import Foundation
import Metal
import ImagingCore

/// 对校正后的完整输入计算带版本的线性 sRGB 面积统计，采样范围始终覆盖整帧。
public final class FrameFeatureExtractor {
    public static let algorithmVersion = "linear-srgb-summary-v1"
    private let device: MTLDevice
    private let area: MTLComputePipelineState
    private let summary: MTLComputePipelineState
    private let combine: MTLComputePipelineState
    public init(device: MTLDevice) throws {
        self.device = device
        let options = MTLCompileOptions()
        options.fastMathEnabled = false // Preserve compensated sums and nonfinite checks.
        let library = try RenderingResources.makeLibrary(device: device, options: options)
        guard let a = library.makeFunction(name: "frameFeatureAreaV1"), let s = library.makeFunction(name: "frameFeatureSummaryV1"), let c = library.makeFunction(name: "frameFeatureCombineV1") else { throw LabError.io("Missing frame feature kernels") }
        area = try device.makeComputePipelineState(function: a)
        summary = try device.makeComputePipelineState(function: s)
        combine = try device.makeComputePipelineState(function: c)
    }
    /// 编码面积采样和归约，由调用方提交。只需拍摄元数据时可直接解析结果。
    public func encode(_ input: PreparedInput, stamp: FrameStamp, requirements: ObservationRequirements, commandBuffer: MTLCommandBuffer) throws -> ObservationReadback {
        try encode(input, stamp: stamp, requirements: requirements, commandBuffer: commandBuffer, budgetLimit: nil)
    }
    func encode(_ input: PreparedInput, stamp: FrameStamp, requirements: ObservationRequirements,
                commandBuffer: MTLCommandBuffer, budgetLimit: Int?, workingSet: TileWorkingSet? = nil) throws -> ObservationReadback {
        try stamp.validate(); try requirements.validate(); try input.working.validate()
        guard input.texture.device.registryID == device.registryID, commandBuffer.device.registryID == device.registryID,
              commandBuffer.status == .notEnqueued, commandBuffer.retainedReferences else { throw LabError.invalid("Feature command/device mismatch or unretained command") }
        guard requirements.features.count <= 64, requirements.features.allSatisfy({ $0.samplingLongEdge == 256 }) else {
            throw LabError.unsupported("Feature summary v1 supports up to 64 features on the fixed 256 sampling grid")
        }
        var observation = FrameObservations(stamp: stamp, sourceID: input.sourceID, calibrationID: input.calibrationID, featureDigest: try requirements.featureDigest())
        observation.captureConditions = input.captureConditions
        if requirements.features.isEmpty {
            return ObservationReadback(observation: observation, features: [], buffer: nil, command: nil, width: 0, height: 0, partitions: 0)
        }
        let scale = min(1, 256 / Double(max(input.width, input.height)))
        let width = max(1, Int(floor(Double(input.width) * scale))), height = max(1, Int(floor(Double(input.height) * scale)))
        let count = width * height, bytes = (262 + requirements.features.count) * 4
        let partitions = (count + 255) / 256, partialBytes = partitions * bytes
        // 预算包含 PreparedInput 保留的原始和校正后纹理，共用存储时只计一次。
        // 跨帧预留由会话共享的预算账本负责。
        let inputBytes = input.texture.allocatedSize + (input.texture === input.source.texture ? 0 : input.source.texture.allocatedSize)
        let budget = min(input.execution.budget.maxResidentBytes, budgetLimit ?? Int.max)
        let available = budget - min(budget, inputBytes)
        let sizes = [(count * 16, MTLResourceOptions.storageModePrivate), (partialBytes, .storageModePrivate), (bytes, .storageModeShared)]
        let allocation = sizes.reduce(0) { $0 + device.heapBufferSizeAndAlign(length: $1.0, options: $1.1).size }
        guard allocation <= available else { throw LabError.invalid("Feature statistics exceed available memory budget") }
        try workingSet?.reserve(allocation)
        guard count * 16 + partialBytes + bytes <= available,
              let samples = device.makeBuffer(length: count * 16, options: .storageModePrivate),
              let partials = device.makeBuffer(length: partialBytes, options: .storageModePrivate),
              let output = device.makeBuffer(length: bytes, options: .storageModeShared) else { throw LabError.invalid("Feature statistics exceed available memory budget") }
        guard samples.allocatedSize + partials.allocatedSize + output.allocatedSize <= available else { throw LabError.invalid("Feature statistics exceed available memory budget") }
        let actual = samples.allocatedSize + partials.allocatedSize + output.allocatedSize
        if actual > allocation { try workingSet?.reserve(actual - allocation) }
        var dimensions = SIMD2<UInt32>(UInt32(width), UInt32(height))
        var featureCount = UInt32(requirements.features.count)
        // 按比较方向舍入 Double 阈值，保留对 Float32 样本的包含边界。
        var requests = requirements.features.map { feature -> SIMD2<Float> in
            switch feature.statistic {
            case .fractionBelow(let t):
                let rounded = Float(t)
                return .init(1, Double(rounded) > t ? rounded.nextDown : rounded)
            case .fractionAbove(let t):
                let rounded = Float(t)
                return .init(2, Double(rounded) < t ? rounded.nextUp : rounded)
            default: return .zero
            }
        }
        guard requests.allSatisfy({ $0.y.isFinite }), let encoder = commandBuffer.makeComputeCommandEncoder() else { throw LabError.invalid("Unsupported feature threshold or encoder unavailable") }
        encoder.setComputePipelineState(area); encoder.setTexture(input.texture, index: 0)
        encoder.setBuffer(samples, offset: 0, index: 0); encoder.setBytes(&dimensions, length: 8, index: 1)
        encoder.dispatchThreads(.init(width: width, height: height, depth: 1), threadsPerThreadgroup: .init(width: 8, height: 8, depth: 1))
        encoder.setComputePipelineState(summary)
        encoder.setBuffer(samples, offset: 0, index: 0); encoder.setBuffer(partials, offset: 0, index: 1)
        var sampleCount = UInt32(count)
        encoder.setBytes(&sampleCount, length: 4, index: 2)
        requests.withUnsafeMutableBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 3) }
        encoder.setBytes(&featureCount, length: 4, index: 4)
        encoder.dispatchThreads(.init(width: partitions, height: 1, depth: 1), threadsPerThreadgroup: .init(width: min(64, summary.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
        encoder.setComputePipelineState(combine)
        encoder.setBuffer(partials, offset: 0, index: 0); encoder.setBuffer(output, offset: 0, index: 1)
        var partitionCount = UInt32(partitions)
        encoder.setBytes(&partitionCount, length: 4, index: 3)
        encoder.dispatchThreads(.init(width: 262 + requirements.features.count, height: 1, depth: 1), threadsPerThreadgroup: .init(width: combine.threadExecutionWidth, height: 1, depth: 1))
        encoder.endEncoding()
        return ObservationReadback(observation: observation, features: requirements.features, buffer: output, command: commandBuffer, width: width, height: height, partitions: partitions)
    }
}
