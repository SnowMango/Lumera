import Foundation
import CoreImage
import ImageIO
import ImagingCore

extension LumeraRenderer {
    /// Develops a RAW/Apple ProRAW file and renders it to a completed CIImage.
    ///
    /// Uses the system CIRAWFilter decoder, not an embedded preview. The default keeps system
    /// as-shot white balance and development settings, disables draft mode and requests SDR, or default EDR when `options.dynamicRange = .edr`.
    /// Supported cameras/DNG encodings depend on the running OS. Output is a developed sRGB image (extended sRGB in EDR mode), not an editable RAW/DNG; retain the original file separately.
    ///
    /// - Parameters:
    ///   - url: A readable local RAW file. No network download or security-scoped access is performed.
    ///   - style: A prepared style on this renderer's device.
    ///   - options: Common rendering settings; resizing happens after RAW development.
    ///   - correction: Optional prepared device correction.
    ///   - configureRAW: Called once after defaults and before outputImage is evaluated. Change
    ///     exposure, white balance or other supported decoder settings here. Do not retain/mutate
    ///     the filter concurrently. Throw to abort. Capture EXIF is not replaced by these edits.
    /// - Returns: An independently owned CIImage with supported capture metadata, normalized
    ///   orientation and current dimensions/color. RAW-only instructions and auxiliary data are omitted.
    /// - Throws: Unreadable/unsupported RAW, configuration errors, rendering errors or cancellation.
    public func render(rawURL url: URL, style: PreparedCameraStyle, options: RenderOptions = .init(),
                       correction: PreparedDeviceCorrection? = nil,
                       configureRAW: ((CIRAWFilter) throws -> Void)? = nil) async throws -> CIImage {
        try Task.checkCancellation()
        guard url.isFileURL, let filter = CIRAWFilter(imageURL: url) else {
            throw LabError.unsupported("无法打开 RAW 文件，或系统不支持此 RAW 编码")
        }
        return try await renderRAW(filter, style: style, options: options, correction: correction, configureRAW: configureRAW)
    }

    /// Develops complete RAW/Apple ProRAW file bytes (for example DNG data) and renders a CIImage.
    /// This is not a raw sensor-plane byte buffer. Uses the same defaults, metadata policy and
    /// configuration-closure contract as `render(rawURL:style:options:correction:configureRAW:)`.
    /// For caller-owned CIRAWFilter development, instead pass its outputImage to the CIImage
    /// overload, `metadata: filter.properties as? [String: Any]`, and `orientation: .up` to avoid a second rotation.
    public func render(rawData data: Data, style: PreparedCameraStyle, options: RenderOptions = .init(),
                       correction: PreparedDeviceCorrection? = nil,
                       configureRAW: ((CIRAWFilter) throws -> Void)? = nil) async throws -> CIImage {
        try Task.checkCancellation()
        guard let filter = CIRAWFilter(imageData: data, identifierHint: nil) else {
            throw LabError.unsupported("无法解码 RAW 数据，或系统不支持此 RAW 编码")
        }
        return try await renderRAW(filter, style: style, options: options, correction: correction, configureRAW: configureRAW)
    }

    private func renderRAW(_ filter: CIRAWFilter, style: PreparedCameraStyle, options: RenderOptions,
                           correction: PreparedDeviceCorrection?, configureRAW: ((CIRAWFilter) throws -> Void)?) async throws -> CIImage {
        let developed = try developRAW(filter, dynamicRange: options.dynamicRange, configure: configureRAW)
        let image = developed.image, properties = developed.properties
        return try await render(image, metadata: properties, orientation: .up, style: style,
                                options: options, correction: correction)
    }
    /// 两条图像入口共用的系统 RAW 显影步骤，输出方向已由解码器应用。
    func developRAW(_ filter: CIRAWFilter, dynamicRange: RenderDynamicRange, configure: ((CIRAWFilter) throws -> Void)?) throws
        -> (image: CIImage, properties: [String: Any]) {
        filter.isDraftModeEnabled = false
        filter.extendedDynamicRangeAmount = dynamicRange == .edr ? 1 : 0
        try configure?(filter)
        try Task.checkCancellation()
        guard let image = filter.outputImage else { throw LabError.unsupported("系统 RAW 显影失败") }
        // 保留拍摄元数据供下游使用，方向已写入显影像素。
        let properties = filter.properties as? [String: Any] ?? [:]
        return (image, properties)
    }
}
