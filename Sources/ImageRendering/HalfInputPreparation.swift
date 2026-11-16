import Foundation
import CoreImage
import Metal
import ImagingCore

extension LumeraRenderer {

    /// Each input pixel is rendered by CI once, then checked/converted/measured in one GPU
    /// traversal. Full staging uses one submission; tighter budgets use bounded tile batches.
    /// No partial output is published if any tile fails validation or the task is cancelled.
    func prepareHalfInput(_ image: CIImage, bounds: CGRect, colorSpace: CGColorSpace,
                          budget: Int) async throws -> (texture: MTLTexture, bounds: NumericBounds) {
        try Task.checkCancellation()
        guard bounds == bounds.integral, let width = Int(exactly: bounds.width),
              let height = Int(exactly: bounds.height), width > 0, height > 0,
              bounds.minX.isFinite, bounds.minY.isFinite, budget > 0 else {
            throw LabError.invalid("Invalid Half input preparation extent or budget")
        }
        try TextureDimensions.validate(width: width, height: height, device: device)
        func descriptor(_ format: MTLPixelFormat, _ w: Int, _ h: Int) -> MTLTextureDescriptor {
            let value = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
            value.storageMode = .private; value.usage = [.shaderRead, .shaderWrite]
            return value
        }
        let outputDescriptor = descriptor(.rgba16Float, width, height)
        let outputBytes = device.heapTextureSizeAndAlign(descriptor: outputDescriptor).size
        guard outputBytes < budget else { throw TileAllocationLimit() }
        var edge = max(width, height)
        func stagingDescriptor() -> MTLTextureDescriptor { descriptor(.rgba32Float, min(edge, width), min(edge, height)) }
        func fits(_ d: MTLTextureDescriptor) -> Bool {
            let stagingBytes = device.heapTextureSizeAndAlign(descriptor: d).size
            let rangeBytes = rangeReducer.estimatedBytes(width: d.width, height: d.height)
            return stagingBytes <= budget - outputBytes && rangeBytes <= budget - outputBytes - stagingBytes
        }
        while edge > 1, !fits(stagingDescriptor()) { edge /= 2 }
        let stagingDescription = stagingDescriptor()
        guard fits(stagingDescription) else { throw TileAllocationLimit() }
        let stagingBytes = device.heapTextureSizeAndAlign(descriptor: stagingDescription).size
        let firstRangeBytes = rangeReducer.estimatedBytes(width: stagingDescription.width, height: stagingDescription.height)
        let admission = TileWorkingSet(limit: budget)
        try admission.reserve(outputBytes); try admission.reserve(stagingBytes); try admission.reserve(firstRangeBytes)
        guard let output = device.makeTexture(descriptor: outputDescriptor) else { throw LabError.io("Cannot allocate Half input output") }
        try admission.reserve(max(0, output.allocatedSize - outputBytes))
        guard let staging = device.makeTexture(descriptor: stagingDescription) else { throw LabError.io("Cannot allocate Half input staging") }
        try admission.reserve(max(0, staging.allocatedSize - stagingBytes))
        let residentBytes = max(outputBytes, output.allocatedSize) + max(stagingBytes, staging.allocatedSize)
        var x = 0, y = 0
        var lower = Double.infinity, upper = -Double.infinity
        while y < height {
            try Task.checkCancellation()
            let workspace = TileWorkingSet(limit: budget)
            try workspace.reserve(residentBytes)
            guard let command = queue.makeCommandBuffer() else { throw LabError.io("Cannot create Half input command") }
            command.label = "Lumera.input.half.prepare"
            var readbacks: [InputRangeReadback] = []
            while y < height, readbacks.count < 8 {
                let w = min(staging.width, width - x), h = min(staging.height, height - y)
                guard rangeReducer.estimatedBytes(width: w, height: h) <= workspace.limit - workspace.bytes else { break }
                let area = CGRect(x: bounds.minX + CGFloat(x), y: bounds.minY + CGFloat(y), width: CGFloat(w), height: CGFloat(h))
                context.render(image, to: staging, commandBuffer: command, bounds: area, colorSpace: colorSpace)
                readbacks.append(try rangeReducer.encodeHalfPreparation(staging, output: output, commandBuffer: command,
                    workingSet: workspace, width: w, height: h, outputOrigin: .init(UInt32(x), UInt32(y))))
                x += w
                if x == width { x = 0; y += h }
            }
            guard !readbacks.isEmpty else { throw TileAllocationLimit() }
            try await complete(command)
            for readback in readbacks {
                let actual = try readback.resolve()
                lower = min(lower, actual.lower); upper = max(upper, actual.upper)
            }
        }
        return (output, .init(lower: lower, upper: upper))
    }
}
