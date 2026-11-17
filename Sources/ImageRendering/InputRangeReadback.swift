import Foundation
import Metal
import ImagingCore

/// 将完整纹理的 RGB 数值范围归约到小缓冲区，命令提交由调用方负责。
final class InputRangeReducer {
    private let device: MTLDevice
    private let pipeline: MTLComputePipelineState
    private let reduction: MTLComputePipelineState
    private let halfPreparation: MTLComputePipelineState
    init(device: MTLDevice) throws {
        self.device = device
        let options = MTLCompileOptions()
        options.fastMathEnabled = false // Range validation must preserve NaN and infinity checks.
        let library = try RenderingResources.makeLibrary(device: device, options: options)
        guard let function = library.makeFunction(name: "inputRangeTiles") else { throw LabError.io("Missing input range kernel") }
        pipeline = try device.makeComputePipelineState(function: function)
        guard let reduce = library.makeFunction(name: "inputRangeReduce") else { throw LabError.io("Missing input range reduction kernel") }
        reduction = try device.makeComputePipelineState(function: reduce)
        guard let prepare = library.makeFunction(name: "prepareHalfInputTiles") else { throw LabError.io("Missing Half input preparation kernel") }
        halfPreparation = try device.makeComputePipelineState(function: prepare)
        guard reduction.maxTotalThreadsPerThreadgroup >= 256, halfPreparation.maxTotalThreadsPerThreadgroup >= 256 else {
            throw LabError.unsupported("Input range reduction requires 256 threads per group")
        }
    }
    /// All intermediate allocations live through the command, including each
    /// reduction level. Used by callers when choosing a bounded staging size.
    func estimatedBytes(width: Int, height: Int) -> Int {
        var count = ((width + 15) / 16) * ((height + 15) / 16)
        var bytes = device.heapBufferSizeAndAlign(length: count * 16, options: .storageModePrivate).size
        repeat {
            count = (count + 255) / 256
            bytes += device.heapBufferSizeAndAlign(length: count * 16,
                options: count == 1 ? .storageModeShared : .storageModePrivate).size
        } while count > 1
        return bytes
    }

    func encode(_ input: MTLTexture, commandBuffer: MTLCommandBuffer,
                workingSet: TileWorkingSet? = nil, width: Int? = nil, height: Int? = nil, resources: ProcessingResources? = nil) throws -> InputRangeReadback {
        try encode(input, halfOutput: nil, commandBuffer: commandBuffer, workingSet: workingSet, width: width, height: height, resources: resources)
    }

    /// Checks source pixels before narrowing, writes Half pixels and measures those exact values
    /// in the same traversal. No texture can be published until the returned ticket resolves.
    func encodeHalfPreparation(_ input: MTLTexture, output: MTLTexture, commandBuffer: MTLCommandBuffer,
                               workingSet: TileWorkingSet, width: Int? = nil, height: Int? = nil,
                               outputOrigin: SIMD2<UInt32> = .zero, resources: ProcessingResources? = nil) throws -> InputRangeReadback {
        let w = width ?? input.width, h = height ?? input.height
        guard input.pixelFormat == .rgba32Float, output.pixelFormat == .rgba16Float,
              output.device.registryID == device.registryID,
              w > 0, h > 0, UInt64(outputOrigin.x) + UInt64(w) <= UInt64(output.width),
              UInt64(outputOrigin.y) + UInt64(h) <= UInt64(output.height) else {
            throw LabError.invalid("Invalid Half preparation textures")
        }
        return try encode(input, halfOutput: output, commandBuffer: commandBuffer, workingSet: workingSet, width: width, height: height, outputOrigin: outputOrigin, resources: resources)
    }

    private func encode(_ input: MTLTexture, halfOutput: MTLTexture?, commandBuffer: MTLCommandBuffer,
                        workingSet: TileWorkingSet?, width: Int?, height: Int?,
                        outputOrigin: SIMD2<UInt32> = .zero, resources: ProcessingResources? = nil) throws -> InputRangeReadback {
        let pixelWidth = width ?? input.width, pixelHeight = height ?? input.height
        guard commandBuffer.status == .notEnqueued, commandBuffer.retainedReferences,
              input.device.registryID == device.registryID, commandBuffer.device.registryID == device.registryID,
              pixelWidth > 0, pixelHeight > 0, pixelWidth <= input.width, pixelHeight <= input.height else {
            throw LabError.invalid("Range measurement command/device mismatch")
        }
        try resources?.checkRangeDevice(device.registryID)
        let retention = RangeCommandBuffers()
        commandBuffer.addCompletedHandler { [retention] _ in retention.complete() }
        var readbackLease: ProcessingBufferLease?
        func allocate(_ count: Int, shared: Bool) throws -> MTLBuffer {
            let options: MTLResourceOptions = shared ? .storageModeShared : .storageModePrivate
            let estimate = device.heapBufferSizeAndAlign(length: count * 16, options: options).size
            try workingSet?.reserve(estimate)
            if let resources {
                let lease = try resources.acquireRangeBuffer(length: count * 16, options: options)
                try workingSet?.reserve(max(0, lease.bytes - estimate))
                retention.retain(lease)
                if shared { readbackLease = lease }
                return lease.buffer
            }
            guard let buffer = device.makeBuffer(length: count * 16, options: options) else {
                throw LabError.io("Cannot allocate input range reduction")
            }
            try workingSet?.reserve(max(0, buffer.allocatedSize - estimate))
            return buffer
        }
        let width = (pixelWidth + 15) / 16, height = (pixelHeight + 15) / 16
        var count = width * height
        var buffer = try allocate(count, shared: false)
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw LabError.io("Cannot encode input range") }
        var size = SIMD2<UInt32>(UInt32(pixelWidth), UInt32(pixelHeight))
        let selectedPipeline = halfOutput == nil ? pipeline : halfPreparation
        encoder.setComputePipelineState(selectedPipeline); encoder.setTexture(input, index: 0); encoder.setBuffer(buffer, offset: 0, index: 0)
        if let halfOutput {
            encoder.setTexture(halfOutput, index: 1)
            var origin = outputOrigin
            encoder.setBytes(&origin, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 3)
            // Round the CPU ceiling downward so a Float32 uniform cannot admit a value above it.
            let ceiling = PrecisionSafety.halfStorageCeiling
            var limit = Float(ceiling)
            if Double(limit) > ceiling { limit = limit.nextDown }
            encoder.setBytes(&limit, length: MemoryLayout<Float>.stride, index: 2)
        }
        encoder.setBytes(&size, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 1)
        if halfOutput != nil {
            encoder.dispatchThreadgroups(.init(width: width, height: height, depth: 1),
                threadsPerThreadgroup: .init(width: 16, height: 16, depth: 1))
        } else {
            let w = pipeline.threadExecutionWidth, h = max(1, min(8, pipeline.maxTotalThreadsPerThreadgroup / w))
            encoder.dispatchThreads(.init(width: width, height: height, depth: 1), threadsPerThreadgroup: .init(width: w, height: h, depth: 1))
        }
        encoder.endEncoding()
        repeat {
            let groups = (count + 255) / 256
            let output = try allocate(groups, shared: groups == 1)
            guard let reduce = commandBuffer.makeComputeCommandEncoder() else { throw LabError.io("Cannot encode input range reduction") }
            var inputCount = UInt32(count)
            reduce.setComputePipelineState(reduction)
            reduce.setBuffer(buffer, offset: 0, index: 0); reduce.setBuffer(output, offset: 0, index: 1)
            reduce.setBytes(&inputCount, length: MemoryLayout<UInt32>.stride, index: 2)
            reduce.dispatchThreadgroups(.init(width: groups, height: 1, depth: 1),
                threadsPerThreadgroup: .init(width: 256, height: 1, depth: 1))
            reduce.endEncoding()
            buffer = output; count = groups
        } while count > 1
        return InputRangeReadback(buffer: buffer, count: 1, command: commandBuffer, requiresHalfSafety: halfOutput != nil, lease: readbackLease)
    }
}
/// 读取时合并分块范围，并拒绝任一分块报告的非有限样本。
struct InputRangeReadback {
    private let state: RangeReadbackState
    let count: Int
    /// Available only before resolution; resolved tickets retain values, not GPU storage.
    var buffer: MTLBuffer? { state.buffer }
    init(buffer: MTLBuffer, count: Int, command: MTLCommandBuffer, requiresHalfSafety: Bool = false,
         lease: ProcessingBufferLease? = nil) {
        self.count = count
        state = RangeReadbackState(buffer: buffer, command: command, count: count,
                                   requiresHalfSafety: requiresHalfSafety, lease: lease)
    }
    func resolve() throws -> NumericBounds { try state.resolve() }
}

/// Copies share GPU ownership until resolution, then only the cached terminal result.
private final class RangeReadbackState: @unchecked Sendable {
    private let lock = UnfairLock()
    private var storage: MTLBuffer?
    private var command: MTLCommandBuffer?
    private var lease: ProcessingBufferLease?
    private let count: Int
    private let requiresHalfSafety: Bool
    private var result: Result<NumericBounds, Error>?
    var buffer: MTLBuffer? { lock.withLock { storage } }
    init(buffer: MTLBuffer, command: MTLCommandBuffer, count: Int, requiresHalfSafety: Bool, lease: ProcessingBufferLease?) {
        storage = buffer; self.command = command; self.count = count
        self.requiresHalfSafety = requiresHalfSafety; self.lease = lease
    }
    func resolve() throws -> NumericBounds {
        try lock.withLock {
            if let result { return try result.get() }
            guard let command, command.status == .completed || command.status == .error else {
                throw LabError.invalid("Range readback requires GPU completion")
            }
            let value = Result<NumericBounds, Error> {
                guard command.status == .completed, command.error == nil else {
                    throw command.error ?? LabError.invalid("Range readback GPU command failed")
                }
                guard let storage else { throw LabError.invalid("Missing range readback storage") }
                return try Self.readBounds(buffer: storage, count: count, requiresHalfSafety: requiresHalfSafety)
            }
            result = value
            storage = nil; self.command = nil; lease = nil
            return try value.get()
        }
    }
    private static func readBounds(buffer: MTLBuffer, count: Int, requiresHalfSafety: Bool) throws -> NumericBounds {
        let values = buffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: count)
        var lower = Float.infinity, upper = -Float.infinity
        for i in 0..<count {
            let value = values[i]
            guard value.z == 0, value.x.isFinite, value.y.isFinite else { throw LabError.invalid("Input contains NaN or infinity") }
            if requiresHalfSafety, value.w != 0 {
                throw LabError.unsupported("Input exceeds safe Float16 storage")
            }
            lower = min(lower, value.x); upper = max(upper, value.y)
        }
        let bounds = NumericBounds(lower: Double(lower), upper: Double(upper))
        try bounds.validate(); return bounds
    }
}
