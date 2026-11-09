import Foundation
import Metal
import ImagingCore

/// 将完整纹理的 RGB 数值范围归约到小缓冲区，命令提交由调用方负责。
final class InputRangeReducer {
    private let device: MTLDevice
    private let pipeline: MTLComputePipelineState
    init(device: MTLDevice) throws {
        self.device = device
        let library = try RenderingResources.makeLibrary(device: device)
        guard let function = library.makeFunction(name: "inputRangeTiles") else { throw LabError.io("Missing input range kernel") }
        pipeline = try device.makeComputePipelineState(function: function)
    }
    func encode(_ input: MTLTexture, commandBuffer: MTLCommandBuffer) throws -> InputRangeReadback {
        guard commandBuffer.status == .notEnqueued, commandBuffer.retainedReferences,
              input.device.registryID == device.registryID, commandBuffer.device.registryID == device.registryID else {
            throw LabError.invalid("Range measurement command/device mismatch")
        }
        let width = (input.width + 15) / 16, height = (input.height + 15) / 16
        guard let buffer = device.makeBuffer(length: width * height * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { throw LabError.io("Cannot allocate input range readback") }
        encoder.setComputePipelineState(pipeline); encoder.setTexture(input, index: 0); encoder.setBuffer(buffer, offset: 0, index: 0)
        let w = pipeline.threadExecutionWidth, h = max(1, min(8, pipeline.maxTotalThreadsPerThreadgroup / w))
        encoder.dispatchThreads(.init(width: width, height: height, depth: 1), threadsPerThreadgroup: .init(width: w, height: h, depth: 1))
        encoder.endEncoding()
        return InputRangeReadback(buffer: buffer, count: width * height, command: commandBuffer)
    }
}
/// 读取时合并分块范围，并拒绝任一分块报告的非有限样本。
struct InputRangeReadback {
    let buffer: MTLBuffer
    let count: Int
    let command: MTLCommandBuffer
    func resolve() throws -> NumericBounds {
        guard command.status == .completed, command.error == nil else { throw LabError.invalid("Range readback requires successful GPU completion") }
        let values = buffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: count)
        var lower = Float.infinity, upper = -Float.infinity
        for i in 0..<count {
            let value = values[i]
            guard value.z == 0, value.x.isFinite, value.y.isFinite else { throw LabError.invalid("Input contains NaN or infinity") }
            lower = min(lower, value.x); upper = max(upper, value.y)
        }
        let bounds = NumericBounds(lower: Double(lower), upper: Double(upper))
        try bounds.validate(); return bounds
    }
}
