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
    /// The adapter converts tagged SDR colors to sRGB, composites transparency over black,
    /// normalizes the extent origin and applies orientation once. Untagged CIImage pixels follow
    /// Core Image working-space semantics (extended linear sRGB here), not an encoded-sRGB guess.
    /// Tag encoded source pixels with their actual color space when constructing the CIImage.
    /// The result is opaque sRGB SDR with floating-point RGBA storage (normally half-float), even for a neutral style.
    /// Known HDR headroom is tone-mapped on iOS 18/macOS 15 or newer. HDR that cannot be
    /// reliably mapped on the running OS throws; this API does not preserve HDR output.
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
                       style: PreparedCameraStyle, options: RenderOptions = .init(),
                       correction: PreparedDeviceCorrection? = nil) async throws -> CIImage {
        try Task.checkCancellation()
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
        let request = options.makeRequest(input: InputDescriptor(width: width, height: height))
        try request.validate()
        try TextureDimensions.validate(width: width, height: height, device: device)
        var normalized = try sdrImage(oriented)
        normalized = normalized.transformed(by: CGAffineTransform(translationX: -integral.minX, y: -integral.minY))
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)).cropped(to: bounds)
        normalized = normalized.composited(over: black).cropped(to: bounds)
        // Explicit SDR gamut/range boundary after source color management in linear sRGB.
        normalized = normalized.applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)])
        let inputDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
            width: width, height: height, mipmapped: false)
        inputDescriptor.usage = [.shaderRead, .shaderWrite]
        inputDescriptor.storageMode = .private
        guard let input = device.makeTexture(descriptor: inputDescriptor), let command = queue.makeCommandBuffer() else {
            throw LabError.io("无法分配图像输入纹理或 GPU 任务")
        }
        context.render(normalized, to: input, commandBuffer: command, bounds: bounds, colorSpace: Self.sRGB)
        let rendered = try encoder.encode(input, style: style, correction: correction, request: request, commandBuffer: command)
        let ownedDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: rendered.pixelFormat,
            width: rendered.width, height: rendered.height, mipmapped: false)
        ownedDescriptor.storageMode = .private
        ownedDescriptor.usage = [.shaderRead]
        guard let owned = device.makeTexture(descriptor: ownedDescriptor), let blit = command.makeBlitCommandEncoder() else {
            throw LabError.io("无法创建独立图像输出")
        }
        // Copy while the encoder's pooled result is still reserved by this command buffer.
        blit.copy(from: rendered, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: rendered.width, height: rendered.height, depth: 1),
                  to: owned, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        try await complete(command)
        guard let result = CIImage(mtlTexture: owned, options: [.colorSpace: Self.sRGB]) else {
            throw LabError.io("无法创建 Core Image 输出")
        }
        return result.settingProperties(LumeraImageMetadata.output(sourceProperties,
            width: owned.width, height: owned.height, depth: owned.pixelFormat == .rgba32Float ? 32 : 16))
    }

    /// Renders a pixel buffer to an independently owned, completed BGRA8 sRGB SDR pixel buffer.
    ///
    /// Core Image decodes supported RGB/YCbCr buffers using their color attachments. Untagged
    /// RGB assumes sRGB; YCbCr requires a resolvable attached color space. Clean apertures other
    /// than the full frame, non-square pixel aspect ratios and interlaced buffers are rejected.
    /// Raw sensor buffers must instead be developed through the RAW API or an external CIRAWFilter.
    ///
    /// Both attachment modes are used to interpret source geometry and orientation, but only
    /// propagating capture attachments are eligible for output. Known ImageIO capture dictionaries survive;
    /// stale YCbCr, ICC/gamma, HDR, geometry, camera-calibration and unknown attachments are not
    /// copied. New RGB color attachments match the BGRA8 output. Metadata and orientation overrides
    /// follow the CIImage overload. CVPixelBuffer does not carry CMSampleBuffer timing: keep timing
    /// separately when rebuilding a sample buffer. Keep the input unchanged until completion.
    ///
    /// - Returns: A new opaque buffer; its pixel format may differ from the input. Later external
    ///   processing is responsible for updating attachments after its own changes.
    /// - Throws: Unsupported input layout/color, invalid options, allocation/GPU errors or cancellation.
    public func render(_ buffer: CVPixelBuffer, metadata: [String: Any]? = nil,
                       orientation: CGImagePropertyOrientation? = nil,
                       style: PreparedCameraStyle, options: RenderOptions = .init(),
                       correction: PreparedDeviceCorrection? = nil) async throws -> CVPixelBuffer {
        try Task.checkCancellation()
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
        let rendered = try await render(image.settingProperties(attachments), metadata: properties,
            orientation: orientation ?? LumeraImageMetadata.orientation(sourceInterpretation),
            style: style, options: options, correction: correction)
        let width = Int(rendered.extent.width), height = Int(rendered.extent.height)
        var output: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true]
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &output) == kCVReturnSuccess,
              let output else { throw LabError.io("无法分配输出像素缓冲区") }
        context.render(rendered, to: output, bounds: rendered.extent, colorSpace: Self.sRGB)
        LumeraImageMetadata.attach(LumeraImageMetadata.output(rendered.properties, width: width, height: height, depth: 8), to: output)
        try Task.checkCancellation()
        return output
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

    private func complete(_ command: MTLCommandBuffer) async throws {
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

    private func validateBuffer(_ buffer: CVPixelBuffer, attachments: [String: Any]) throws {
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
