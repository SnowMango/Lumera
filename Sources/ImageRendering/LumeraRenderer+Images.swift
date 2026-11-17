import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import ImageIO
import Metal
import ImagingCore

extension LumeraRenderer {
    /// Renders a finite Core Image image into an independently owned, completed CIImage.
    ///
    /// 单帧便利入口：自动准备本次调用所需资源，返回不受后续渲染影响的独立结果。
    /// 会产生像素存储分配及必要的转换/复制，不提供由调用者控制的输出存储复用。
    /// 适合一次性图像处理；不应将此便利入口当作连续预览或录制的资源复用接口。
    /// 可复用 LumeraRenderer 的上下文和已准备风格，无需每张图创建新的 renderer。
    /// 与显式资源接口共用执行核心；仅准备本帧临时资源，不创建连续帧池或预热额外槽位。
    ///
    /// The adapter converts tagged SDR colors to sRGB, composites transparency over black,
    /// normalizes the extent origin and applies orientation once. Untagged CIImage pixels follow
    /// Core Image working-space semantics (extended linear sRGB here), not an encoded-sRGB guess.
    /// Tag encoded source pixels with their actual color space when constructing the CIImage.
    /// By default the result is opaque sRGB SDR (normally half-float); known HDR headroom
    /// is tone-mapped on iOS 18/macOS 15 or newer, otherwise unsupported HDR throws.
    /// `options.dynamicRange = .edr` 时以所选浮点精度输出编码扩展 sRGB，保留扩展值。
    /// 风格处理后的亮度余量由调用方按显示或编码需求测量。
    ///
    /// - Parameters:
    ///   - image: An image with a finite, nonempty extent. Keep externally backed pixels alive
    ///     and unchanged until this call returns. Fractional extents expand to integral bounds.
    ///   - metadata: Optional ImageIO-style source properties, useful with externally developed
    ///     CIRAWFilter output. Supplied capture fields override matching image properties;
    ///     unrelated nested capture fields are retained. Geometry/color are rebuilt from output.
    ///   - orientation: Overrides the image's orientation property. Pass `.up` if pixels were
    ///     already oriented, including CIRAWFilter.outputImage. Supplemental metadata does not
    ///     determine orientation. Nil reads the image property, defaulting to `.up`.
    ///   - style: A prepared fixed style belonging to this renderer's Metal device.
    ///   - options: The same effect, size and random-sequence settings as the texture overload.
    ///   - correction: Optional independently prepared device correction.
    /// - Returns: An image whose storage remains valid across later renders/cache releases.
    ///   Known EXIF/TIFF capture facts and GPS survive. Dimensions, orientation and color are
    ///   rewritten; maker notes, DNG instructions, thumbnails, auxiliary images and unknown
    ///   properties are omitted. GPS is retained: remove it explicitly before sharing if needed.
    /// - Important: Later external edits must update their own metadata. File encoders must
    ///   explicitly write the returned properties; this method does not create an encoded file.
    /// - Throws: Invalid input/options, unsupported HDR, allocation/GPU errors or cancellation.
    ///   Cancellation after GPU submission waits for safe completion before returning an error.
    public func render(_ image: CIImage, metadata: [String: Any]? = nil,
                       orientation: CGImagePropertyOrientation? = nil,
                       style: PreparedResolvedStyle, options: RenderOptions = .init(),
                       correction: PreparedDeviceCorrection? = nil) async throws -> CIImage {
        try Task.checkCancellation()
        let normalized = try normalizedSource(image, metadata: metadata, orientation: orientation, dynamicRange: options.dynamicRange)
        var effective = options
        // Preserve the legacy single-frame validation contract. The explicit resource
        // path instead uses a caller-declared range and does not perform this scan.
        if imageInputFormat == .rgba16Float {
            effective.inputValueBounds = try await measureInputRange(normalized.image, bounds: normalized.bounds,
                colorSpace: Self.colorSpace(for: options.dynamicRange))
        }
        let prepared = try PreparedProcessingRequest(renderer: self, style: style,
            input: .init(width: Int(normalized.bounds.width), height: Int(normalized.bounds.height)),
            options: effective, correction: correction)
        let resources = try SingleFrameProcessingResources(request: prepared)
        guard let storage = resources.output else { throw LabError.io("Missing single-frame output") }
        let properties = LumeraImageMetadata.output(normalized.properties, width: prepared.outputWidth,
            height: prepared.outputHeight, depth: imageInputFormat == .rgba32Float ? 32 : 16, dynamicRange: options.dynamicRange)
        let output = try CIImageOutput(texture: storage.texture, colorSpace: Self.colorSpace(for: options.dynamicRange), properties: properties)
        // Already normalized; encode exactly once using the same pixel-processing core.
        return try await awaitProcessing { completion in
            processNormalizedImage(normalized.image, bounds: normalized.bounds, output: output.texture,
                result: output.image, context: context, workspace: resources.workspace, request: prepared,
                retaining: [output], completion: completion)
        }
    }

    /// 返回独立像素缓冲区。SDR 使用 BGRA8 sRGB，EDR 使用所选 RGBA 浮点精度及扩展 sRGB。
    ///
    /// 单帧便利入口：自动准备本次调用所需资源并分配独立输出 CVPixelBuffer。
    /// 不接收外部输出缓冲区或纹理映射缓存，不提供调用者控制的输出池复用。
    /// 适合一次性处理；连续帧不应依靠反复调用此便利入口获得低分配开销。
    /// 返回前 GPU 写入已完成；持有结果期间，后续调用不会覆盖其像素。
    /// 与显式资源接口共用执行核心；仅准备本帧临时资源，不创建 CVPixelBufferPool。
    ///
    /// Core Image decodes supported RGB/YCbCr buffers using their color attachments. Untagged
    /// RGB assumes sRGB; YCbCr requires a resolvable attached color space. Clean apertures other
    /// than the full frame, non-square pixel aspect ratios and interlaced buffers are rejected.
    /// Raw sensor buffers must instead be developed through the RAW API or an external CIRAWFilter.
    ///
    /// Both attachment modes are used to interpret source geometry and orientation, but only
    /// propagating capture attachments are eligible for output. Known ImageIO capture dictionaries survive;
    /// stale YCbCr, ICC/gamma, HDR, geometry, camera-calibration and unknown attachments are not
    /// copied. New RGB color attachments match the output encoding and range. Metadata and orientation overrides
    /// follow the CIImage overload. CVPixelBuffer does not carry CMSampleBuffer timing: keep timing
    /// separately when rebuilding a sample buffer. Keep the input unchanged until completion.
    ///
    /// - Returns: A new opaque buffer; its pixel format may differ from the input. Later external
    ///   processing is responsible for updating attachments after its own changes.
    /// - Throws: Unsupported input layout/color, invalid options, allocation/GPU errors or cancellation.
    public func render(_ buffer: CVPixelBuffer, metadata: [String: Any]? = nil,
                       orientation: CGImagePropertyOrientation? = nil,
                       style: PreparedResolvedStyle, options: RenderOptions = .init(),
                       correction: PreparedDeviceCorrection? = nil) async throws -> CVPixelBuffer {
        try Task.checkCancellation()
        let decoded = try interpretedBuffer(buffer, metadata: metadata, orientation: orientation)
        let normalized = try normalizedSource(decoded.image, metadata: decoded.properties,
            orientation: decoded.orientation, dynamicRange: options.dynamicRange)
        var effective = options
        if imageInputFormat == .rgba16Float {
            effective.inputValueBounds = try await measureInputRange(normalized.image, bounds: normalized.bounds,
                colorSpace: Self.colorSpace(for: options.dynamicRange))
        }
        let extended = options.dynamicRange == .edr
        let format: MTLPixelFormat = extended ? imageInputFormat : .bgra8Unorm
        let prepared = try PreparedProcessingRequest(renderer: self, style: style,
            input: .init(width: Int(normalized.bounds.width), height: Int(normalized.bounds.height)),
            options: effective, outputPixelFormat: format, correction: correction)
        let cvFormat = extended ? (imageInputFormat == .rgba16Float ? kCVPixelFormatType_64RGBAHalf : kCVPixelFormatType_128RGBAFloat) : kCVPixelFormatType_32BGRA
        var allocated: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true]
        guard CVPixelBufferCreate(nil, prepared.outputWidth, prepared.outputHeight, cvFormat,
                                  attributes as CFDictionary, &allocated) == kCVReturnSuccess, let output = allocated else {
            throw LabError.io("Cannot allocate single-frame PixelBuffer output")
        }
        let cache = try singleFrameTextureCache()
        let binding = try PixelBufferTextureBinding(output, cache: cache, writable: true)
        let resources = try SingleFrameProcessingResources(request: prepared, output: binding.texture)
        let properties = LumeraImageMetadata.output(normalized.properties, width: prepared.outputWidth,
            height: prepared.outputHeight, depth: extended ? (imageInputFormat == .rgba32Float ? 32 : 16) : 8,
            dynamicRange: options.dynamicRange)
        LumeraImageMetadata.attach(properties, to: output, dynamicRange: options.dynamicRange)
        return try await awaitProcessing { completion in
            processNormalizedImage(normalized.image, bounds: normalized.bounds, output: binding.texture,
                result: output, context: context, workspace: resources.workspace, request: prepared,
                retaining: [binding], completion: completion)
        }
    }

    /// 两类附件共同解释输入，只有可传播的拍摄字段会被传给输出元数据路径。
    func interpretedBuffer(_ buffer: CVPixelBuffer, metadata: [String: Any]?, orientation: CGImagePropertyOrientation?) throws
        -> (image: CIImage, properties: [String: Any], facts: [String: Any], orientation: CGImagePropertyOrientation) {
        let attachments = CVBufferCopyAttachments(buffer, .shouldPropagate) as? [String: Any] ?? [:]
        let nonpropagating = CVBufferCopyAttachments(buffer, .shouldNotPropagate) as? [String: Any] ?? [:]
        let sourceInterpretation = nonpropagating.merging(attachments) { _, propagated in propagated }
        try validateBuffer(buffer, attachments: sourceInterpretation)
        let image: CIImage
        if let colorSpace = CVImageBufferGetColorSpace(buffer)?.takeUnretainedValue() {
            image = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: colorSpace])
        } else {
            guard !CVPixelBufferIsPlanar(buffer) else { throw LabError.unsupported("YCbCr 输入需要完整的颜色附件") }
            image = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: Self.sRGB])
        }
        let properties = LumeraImageMetadata.merge(attachments, supplement: metadata)
        return (image.settingProperties(attachments), properties, LumeraImageMetadata.merge(sourceInterpretation, supplement: metadata), orientation ?? LumeraImageMetadata.orientation(sourceInterpretation))
    }

    /// 在目标色彩空间中以 Float32 逐块测量完整图像，再检查半精度存储所需的余量。
    func measureInputRange(_ image: CIImage, bounds: CGRect, colorSpace: CGColorSpace, budget: Int = 64 * 1024 * 1024, requireHalf: Bool = true, resources: ProcessingResources? = nil) async throws -> NumericBounds {
        try Task.checkCancellation()
        guard budget >= 4096, let width = Int(exactly: bounds.width), let height = Int(exactly: bounds.height),
              width > 0, height > 0, bounds.minX.isFinite, bounds.minY.isFinite else {
            throw LabError.invalid("Invalid input range bounds or memory budget")
        }
        func stagingDescriptor(_ width: Int, _ height: Int) -> MTLTextureDescriptor {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
            descriptor.storageMode = .private; descriptor.usage = [.shaderRead, .shaderWrite]
            return descriptor
        }
        // Fit at least one complete tile before allocating. The remaining budget,
        // rather than an unconditional eight-tile reservation, determines batch size.
        var edge = max(1, min(TextureDimensions.maximumEdge(device: device), Int(sqrt(Double(budget) / 32)), 2048))
        while edge > 1 {
            let w = min(edge, width), h = min(edge, height)
            let staging = device.heapTextureSizeAndAlign(descriptor: stagingDescriptor(w, h)).size
            if staging + rangeReducer.estimatedBytes(width: w, height: h) <= budget { break }
            edge /= 2
        }
        let descriptor = stagingDescriptor(min(edge, width), min(edge, height))
        let stagingEstimate = device.heapTextureSizeAndAlign(descriptor: descriptor).size
        let firstRangeBytes = rangeReducer.estimatedBytes(width: descriptor.width, height: descriptor.height)
        let admission = TileWorkingSet(limit: budget)
        try admission.reserve(stagingEstimate)
        try admission.reserve(firstRangeBytes)
        try Task.checkCancellation()
        guard let staging = device.makeTexture(descriptor: descriptor) else { throw LabError.io("Cannot allocate input range staging") }
        try admission.reserve(max(0, staging.allocatedSize - stagingEstimate))
        let stagingBytes = max(stagingEstimate, staging.allocatedSize)
        var low = Double.infinity, high = -Double.infinity
        var x = 0, y = 0
        while y < height {
            try Task.checkCancellation()
            let workspace = TileWorkingSet(limit: budget)
            try workspace.reserve(stagingBytes)
            guard let command = queue.makeCommandBuffer() else { throw LabError.io("Cannot allocate input range command") }
            var readbacks: [InputRangeReadback] = []
            // Enumerate lazily: CPU storage stays bounded even for huge images and tiny budgets.
            while y < height, readbacks.count < 8 {
                try Task.checkCancellation()
                let w = min(descriptor.width, width - x), h = min(descriptor.height, height - y)
                let rangeBytes = rangeReducer.estimatedBytes(width: w, height: h)
                guard rangeBytes <= workspace.limit - workspace.bytes else { break }
                let area = CGRect(x: bounds.minX + CGFloat(x), y: bounds.minY + CGFloat(y), width: CGFloat(w), height: CGFloat(h))
                // CI writes and range reads share a tracked texture in command order.
                // Edge tiles scan only the valid area, excluding stale staging pixels.
                context.render(image, to: staging, commandBuffer: command, bounds: area, colorSpace: colorSpace)
                readbacks.append(try rangeReducer.encode(staging, commandBuffer: command, workingSet: workspace, width: w, height: h, resources: resources))
                x += w
                if x == width { x = 0; y += h }
            }
            guard !readbacks.isEmpty else { throw TileAllocationLimit() }
            try await complete(command)
            for readback in readbacks {
                let result = try readback.resolve()
                low = min(low, result.lower); high = max(high, result.upper)
            }
        }
        guard low.isFinite, high.isFinite, !requireHalf || max(abs(low), abs(high)) <= 65504 / 1.02 else {
            throw LabError.unsupported("Input exceeds safe Float16 storage; select Float32 explicitly")
        }
        return .init(lower: low, upper: high)
    }

    func normalizedSource(_ image: CIImage, metadata: [String: Any]?, orientation: CGImagePropertyOrientation?, dynamicRange: RenderDynamicRange = .sdr) throws
        -> (image: CIImage, bounds: CGRect, properties: [String: Any]) {
        let sourceProperties = LumeraImageMetadata.merge(image.properties, supplement: metadata)
        let oriented = image.oriented(orientation ?? LumeraImageMetadata.orientation(image.properties))
        let extent = oriented.extent
        guard !extent.isInfinite, !extent.isNull, !extent.isEmpty,
              extent.minX.isFinite, extent.minY.isFinite,
              extent.maxX.isFinite, extent.maxY.isFinite else {
            throw LabError.invalid("图像需要有限且非空的像素范围")
        }
        let integral = extent.integral
        guard integral.width < Double(Int.max), integral.height < Double(Int.max) else {
            throw LabError.invalid("图像尺寸超出整数范围")
        }
        let width = Int(integral.width), height = Int(integral.height)
        var normalized = dynamicRange == .edr ? oriented : try sdrImage(oriented)
        normalized = normalized.transformed(by: CGAffineTransform(translationX: -integral.minX, y: -integral.minY))
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)).cropped(to: bounds)
        normalized = normalized.composited(over: black).cropped(to: bounds)
        // Explicit SDR gamut/range boundary after source color management in linear sRGB.
        if dynamicRange == .sdr {
            normalized = normalized.applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)])
        }
        _ = try ImageDimensions.pixelCount(width: width, height: height)
        return (normalized, bounds, sourceProperties)
    }

    private func sdrImage(_ image: CIImage) throws -> CIImage {
        let taggedHDR = image.colorSpace.map { CGColorSpaceUsesITUR_2100TF($0) } ?? false
        if #available(iOS 18, macOS 15, *) {
            if image.contentHeadroom > 1 {
                let filter = CIFilter.toneMapHeadroom()
                filter.inputImage = image
                filter.sourceHeadroom = image.contentHeadroom
                filter.targetHeadroom = 1
                guard let result = filter.outputImage else { throw LabError.unsupported("无法将 HDR 图像映射到 SDR") }
                return result
            }
        }
        guard !taggedHDR else { throw LabError.unsupported("此 HDR 输入缺少可用的动态范围映射信息，请先显式显影为 SDR") }
        return image
    }

    func complete(_ command: MTLCommandBuffer) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            command.addCompletedHandler { completed in
                if let error = completed.error { continuation.resume(throwing: error) }
                else if completed.status != .completed { continuation.resume(throwing: LabError.io("GPU 图像任务未完成")) }
                else { continuation.resume() }
            }
            command.commit()
        }
        try Task.checkCancellation()
    }

    func validateBuffer(_ buffer: CVPixelBuffer, attachments: [String: Any]) throws {
        let supported: [OSType] = [kCVPixelFormatType_32BGRA, kCVPixelFormatType_32ARGB,
            kCVPixelFormatType_64RGBAHalf, kCVPixelFormatType_128RGBAFloat,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange]
        guard supported.contains(CVPixelBufferGetPixelFormatType(buffer)) else {
            throw LabError.unsupported("不支持此像素缓冲区格式；RAW 数据须先显影")
        }
        if let aspect = attachments[kCVImageBufferPixelAspectRatioKey as String] as? [String: Any] {
            let x = (aspect[kCVImageBufferPixelAspectRatioHorizontalSpacingKey as String] as? NSNumber)?.doubleValue
            let y = (aspect[kCVImageBufferPixelAspectRatioVerticalSpacingKey as String] as? NSNumber)?.doubleValue
            guard let x, let y, x > 0, x == y else { throw LabError.unsupported("输入需要方形像素") }
        }
        for key in [kCVImageBufferCleanApertureKey, kCVImageBufferPreferredCleanApertureKey] {
            if let aperture = attachments[key as String] as? [String: Any] {
                func value(_ key: CFString) -> Double? { (aperture[key as String] as? NSNumber)?.doubleValue }
                guard value(kCVImageBufferCleanApertureWidthKey) == Double(CVPixelBufferGetWidth(buffer)),
                      value(kCVImageBufferCleanApertureHeightKey) == Double(CVPixelBufferGetHeight(buffer)),
                      value(kCVImageBufferCleanApertureHorizontalOffsetKey) == 0,
                      value(kCVImageBufferCleanApertureVerticalOffsetKey) == 0 else {
                    throw LabError.unsupported("请先将 clean aperture 转换为完整像素范围")
                }
            }
        }
        if let count = attachments[kCVImageBufferFieldCountKey as String] as? NSNumber, count.intValue != 1 {
            throw LabError.unsupported("请先将隔行输入转换为逐行图像")
        }
    }
}
