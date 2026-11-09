import Foundation
import CoreImage
import Metal
import ImagingCore

extension LumeraRenderer {
    /// 观测完整的校正后输入，仅需拍摄元数据时省去 GPU 提交。
    public func observe(_ input: PreparedInput, stamp: FrameStamp, requirements: ObservationRequirements, maxResidentBytes: Int? = nil) async throws -> FrameObservations {
        try Task.checkCancellation()
        guard let command = queue.makeCommandBuffer() else { throw LabError.io("Cannot create observation command") }
        let ticket = try frameFeatures.encode(input, stamp: stamp, requirements: requirements, commandBuffer: command, budgetLimit: maxResidentBytes)
        if ticket.readbackBytes > 0 {
            do { try await complete(command) }
            catch is CancellationError { throw CancellationError() }
            catch { throw ModelGPUFailure(message: error.localizedDescription) }
        }
        return try ticket.resolve()
    }
    /// 负责提交并异步取得已完成的独立输出。
    public func render(_ input: PreparedInput, plan: FrameRenderPlan) async throws -> RenderedFrame {
        try Task.checkCancellation()
        let result = try await submit(input, plan: plan, beforeCommit: { try Task.checkCancellation() }).value()
        try Task.checkCancellation()
        return result.frame
    }

    /// 按整帧坐标和累积扩边分块渲染照片或视口，沿用帧计划中的全图决策。
    /// region 为整帧输出坐标系中的整数矩形，省略时输出整帧。
    public func renderTiled(_ input: PreparedInput, plan: FrameRenderPlan, region: CGRect? = nil) async throws -> RenderedFrame {
        try Task.checkCancellation()
        guard input.inputID == plan.inputID, plan.model.renderer === self else { throw LabError.invalid("Tile plan/input identity mismatch") }
        let frame = CGRect(x: 0, y: 0, width: plan.model.execution.width, height: plan.model.execution.height)
        let roi = region ?? frame
        guard roi == roi.integral, !roi.isEmpty, frame.contains(roi) else { throw LabError.invalid("Photo region must be an integer output rectangle") }
        let width = Int(roi.width), height = Int(roi.height), bpp = plan.model.execution.precision.bytesPerPixel
        let count = try ImageDimensions.pixelCount(width: width, height: height)
        try plan.claim()
        var published = false
        defer {
            if published { plan.lease.completeGPU() }
            else { plan.lease.abortUnsubmitted() }
        }
        try plan.workingSet.reserve(count * bpp)
        try plan.lease.retainOutput(bytes: count * bpp)
        let remaining = plan.workingSet.limit - plan.workingSet.bytes
        guard remaining > 0 else { throw LabError.invalid("Photo output leaves no tile workspace") }
        var options = RenderOptions(maximumLongEdge: plan.request.maximumLongEdge, seed: plan.request.seed, frameIndex: plan.request.frameIndex)
        options.dynamicRange = plan.request.dynamicRange; options.previewGlow = plan.request.previewGlow
        options.glowScale = plan.request.glowScale; options.halationScale = plan.request.halationScale; options.softeningScale = plan.request.softeningScale
        let parameters = plan.controls.parameters
        let planner = try TilePlanner(width: input.width, height: input.height, style: parameters, options: options, budget: remaining,
            preparedGrain: parameters.grain.isActive ? plan.style.executionPlan.grain(for: parameters.grain) : nil)
        // 先为完整输出保留 CPU 存储，再逐块复用剩余预算。
        var bytes = Data(count: count * bpp)
        try await planner.forEachTile(region: roi) { tile in
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: self.imageInputFormat,
                width: Int(tile.sourceArea.width), height: Int(tile.sourceArea.height), mipmapped: false)
            descriptor.storageMode = .private; descriptor.usage = [.shaderRead, .shaderWrite]
            try TextureDimensions.validate(width: descriptor.width, height: descriptor.height, device: self.device)
            let workspace = TileWorkingSet(limit: remaining)
            try workspace.reserve(texture: descriptor, on: self.device)
            guard let cropped = self.device.makeTexture(descriptor: descriptor), let command = self.queue.makeCommandBuffer(),
                  let copy = command.makeBlitCommandEncoder() else { throw LabError.io("Cannot allocate photo tile") }
            copy.copy(from: input.texture, sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: .init(x: Int(tile.sourceArea.minX), y: Int(tile.sourceArea.minY), z: 0),
                sourceSize: .init(width: cropped.width, height: cropped.height, depth: 1), to: cropped,
                destinationSlice: 0, destinationLevel: 0, destinationOrigin: .init(x: 0, y: 0, z: 0))
            copy.endEncoding()
            let geometry = RenderGeometry(fullWidth: planner.fullWidth, fullHeight: planner.fullHeight, area: tile.area,
                sourceWidth: planner.sourceWidth, sourceHeight: planner.sourceHeight, sourceArea: tile.sourceArea)
            var request = options.makeRequest(input: .init(width: cropped.width, height: cropped.height))
            request.inputValueBounds = input.valueBounds
            try self.encoder.checkModelSafety(style: plan.style, parameters: parameters, prefix: plan.prefix, request: request, geometry: geometry)
            let output = try self.encoder.encodeModel(cropped, style: plan.style, parameters: parameters, prefix: plan.prefix,
                request: request, workingSet: workspace, geometry: geometry, commandBuffer: command)
            // 扩边只供效果计算，回读仅覆盖无重叠的核心区域。
            let w = Int(tile.core.width), h = Int(tile.core.height), stride = ((w * bpp + 255) / 256) * 256
            try workspace.reserve(bufferLength: stride * h, on: self.device)
            guard let readback = self.device.makeBuffer(length: stride * h, options: .storageModeShared),
                  let blit = command.makeBlitCommandEncoder() else { throw LabError.io("Cannot allocate photo tile readback") }
            blit.copy(from: output, sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: .init(x: Int(tile.core.minX - tile.area.minX), y: Int(tile.core.minY - tile.area.minY), z: 0),
                sourceSize: .init(width: w, height: h, depth: 1), to: readback, destinationOffset: 0,
                destinationBytesPerRow: stride, destinationBytesPerImage: stride * h)
            blit.endEncoding(); try await self.complete(command)
            bytes.withUnsafeMutableBytes { destination in
                for row in 0..<h {
                    let y = height - 1 - (Int(tile.core.minY - roi.minY) + row)
                    let offset = (y * width + Int(tile.core.minX - roi.minX)) * bpp
                    destination.baseAddress!.advanced(by: offset).copyMemory(from: readback.contents().advanced(by: row * stride), byteCount: w * bpp)
                }
            }
        }
        let image = CIImage(bitmapData: bytes, bytesPerRow: width * bpp, size: roi.size, format: bpp == 16 ? .RGBAf : .RGBAh,
            colorSpace: Self.colorSpace(for: plan.request.dynamicRange))
        let result = RenderedFrame(image: image, input: input, plan: plan, region: roi)
        published = true
        return result
    }
}
