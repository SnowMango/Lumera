import CoreImage
import Foundation
import ImagingCore
import Metal

extension LumeraRenderer {
    /// Renders an integer ROI in the oriented, final output coordinate system.
    /// The returned image's origin is zero. Its grain, optics and vignette use full-frame coordinates.
    public func renderRegion(_ image: CIImage, region: CGRect, metadata: [String: Any]? = nil,
                             orientation: CGImagePropertyOrientation? = nil, style: PreparedCameraStyle,
                             options: RenderOptions = .init(), correction: PreparedDeviceCorrection? = nil) async throws -> CIImage {
        try await renderTiles(image, region: region, metadata: metadata, orientation: orientation, style: style,
                              options: options, correction: correction, budget: 128 * 1024 * 1024)
    }

    /// Bounds transient Metal texture work per tile. The complete CPU-backed output, decoder,
    /// caller-owned source and prepared resources have independent lifetimes and budgets.
    public func renderTiled(_ image: CIImage, metadata: [String: Any]? = nil, orientation: CGImagePropertyOrientation? = nil,
                            style: PreparedCameraStyle, options: RenderOptions = .init(),
                            correction: PreparedDeviceCorrection? = nil, workingMemoryLimit: Int = 134217728) async throws -> CIImage {
        try await renderTiles(image, region: nil, metadata: metadata, orientation: orientation, style: style,
                              options: options, correction: correction, budget: workingMemoryLimit)
    }

    private func renderTiles(_ image: CIImage, region: CGRect?, metadata: [String: Any]?, orientation: CGImagePropertyOrientation?,
                             style: PreparedCameraStyle, options: RenderOptions, correction: PreparedDeviceCorrection?, budget: Int) async throws -> CIImage {
        try Task.checkCancellation()
        let source = try normalizedSource(image, metadata: metadata, orientation: orientation, dynamicRange: options.dynamicRange)
        let outputSpace = Self.colorSpace(for: options.dynamicRange)
        let planner = try TilePlanner(width: Int(source.bounds.width), height: Int(source.bounds.height),
                                      style: style.style.parameters, options: options, budget: budget,
                                      preparedGrain: style.style.parameters.grain.isActive ? style.executionPlan.grain(for: style.style.parameters.grain) : nil)
        let frame = CGRect(x:0,y:0,width:planner.fullWidth,height:planner.fullHeight)
        let roi = region ?? frame
        guard roi == roi.integral, !roi.isEmpty, frame.contains(roi) else { throw LabError.invalid("局部范围需要在完整成片内且对齐整数像素") }
        let width = Int(roi.width), height = Int(roi.height)
        let count = try ImageDimensions.pixelCount(width: width, height: height)
        var bytes = Data(), pixelSize = 0
        try await planner.forEachTile(region: roi) { tile in
            let maximumEdge = CGFloat(TextureDimensions.maximumEdge(device:device))
            if [tile.sourceArea.width, tile.sourceArea.height, tile.area.width, tile.area.height].contains(where: { $0 > maximumEdge }) {
                throw TileAllocationLimit()
            }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:inputFormat(for: options.dynamicRange),
                width:Int(tile.sourceArea.width),height:Int(tile.sourceArea.height),mipmapped:false)
            descriptor.storageMode = .private; descriptor.usage = [.shaderRead, .shaderWrite]
            let workingSet = TileWorkingSet(limit:budget)
            try workingSet.reserve(texture:descriptor,on:device)
            guard let input = device.makeTexture(descriptor: descriptor), let command = queue.makeCommandBuffer() else {
                throw LabError.io("分块输入纹理或 GPU 任务分配失败")
            }
            context.render(source.image, to: input, commandBuffer: command, bounds: tile.sourceArea, colorSpace: outputSpace)
            let geometry = RenderGeometry(fullWidth: planner.fullWidth, fullHeight: planner.fullHeight,
                area: tile.area, sourceWidth: planner.sourceWidth, sourceHeight: planner.sourceHeight, sourceArea: tile.sourceArea)
            let request = options.makeRequest(input: .init(width: input.width, height: input.height))
            let output = try encoder.encodeRegion(input, style: style, correction: correction, request: request, geometry: geometry, workingSet:workingSet, commandBuffer: command)
            let bpp = output.pixelFormat == .rgba32Float ? 16 : 8
            let copyWidth = Int(tile.core.width), copyHeight = Int(tile.core.height)
            let stride = ((copyWidth * bpp + 255) / 256) * 256
            try workingSet.reserve(bufferLength:stride * copyHeight,on:device)
            guard let readback = device.makeBuffer(length: stride * copyHeight, options: .storageModeShared),
                  let blit = command.makeBlitCommandEncoder() else { throw LabError.io("分块读回内存不足") }
            blit.copy(from: output, sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x:Int(tile.core.minX-tile.area.minX),y:Int(tile.core.minY-tile.area.minY),z:0),
                sourceSize: MTLSize(width:copyWidth,height:copyHeight,depth:1), to: readback, destinationOffset:0,
                destinationBytesPerRow:stride,destinationBytesPerImage:stride * copyHeight)
            blit.endEncoding()
            try await complete(command)
            if bytes.isEmpty {
                guard let storage = malloc(count * bpp) else { throw LabError.io("无法分配完整成片存储") }
                bytes = Data(bytesNoCopy:storage,count:count * bpp,deallocator:.free)
                pixelSize = bpp
            }
            guard pixelSize == bpp else { throw LabError.io("分块精度不一致") }
            bytes.withUnsafeMutableBytes { (dest: UnsafeMutableRawBufferPointer) in
                for row in 0..<copyHeight {
                    // CIImage(bitmapData:) stores its top row first; CI-to-Metal row zero is y=0.
                    let destY = height - 1 - (Int(tile.core.minY-roi.minY) + row)
                    let offset = (destY * width + Int(tile.core.minX-roi.minX)) * bpp
                    dest.baseAddress!.advanced(by:offset).copyMemory(from:readback.contents().advanced(by:row*stride),byteCount:copyWidth*bpp)
                }
            }
        }
        try Task.checkCancellation()
        let result = CIImage(bitmapData: bytes, bytesPerRow: width * pixelSize, size: roi.size,
                             format: pixelSize == 16 ? .RGBAf : .RGBAh, colorSpace: outputSpace)
        return result.settingProperties(LumeraImageMetadata.output(source.properties,width:width,height:height,depth:pixelSize * 2,dynamicRange:options.dynamicRange))
    }
}
