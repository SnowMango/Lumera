import Foundation
import Metal
import CoreImage
import ImagingCore

/// A shared Metal renderer with native texture, CIImage, CVPixelBuffer and RAW entry points.
///
/// Prepare styles once and reuse this renderer. Native image overloads return completed,
/// independently owned, opaque sRGB SDR images. The texture overload only encodes GPU work.
/// Inputs and prepared resources must not be mutated while an operation uses them.
public final class LumeraRenderer: @unchecked Sendable {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let context: CIContext
    let encoder: TextureEffectEncoder
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Creates a renderer on the supplied device, or the system default device.
    /// Throws if Metal, a command queue or the rendering kernels cannot be created.
    public init(device: MTLDevice? = MTLCreateSystemDefaultDevice(), precision: RenderingPrecision = .float16) throws {
        guard let device, let queue = device.makeCommandQueue() else {
            throw LabError.unsupported("无法创建 Metal 图像渲染环境")
        }
        self.device = device
        self.queue = queue
        self.encoder = try TextureEffectEncoder(device: device, precision: precision)
        self.context = CIContext(mtlDevice: device, options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
            .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])
    }

    /// Validates and prepares a fixed style on this renderer's device. LUT resources are optional.
    public func prepare(_ profile: Profile, lut: LUTAsset? = nil) throws -> PreparedCameraStyle {
        try encoder.prepare(ResolvedStyle(profile: profile), lut: lut)
    }

    /// Prepares an already resolved parameter snapshot without evaluating capture conditions again.
    public func prepare(_ style: ResolvedStyle, lut: LUTAsset? = nil) throws -> PreparedCameraStyle {
        try encoder.prepare(style, lut: lut)
    }

    /// Prepares a dynamic style definition; evaluate its frame parameters separately for each frame.
    public func prepare(_ definition: CompiledStyleDefinition, lut: LUTAsset? = nil) throws -> PreparedStyleDefinition {
        try encoder.prepare(definition, lut: lut)
    }

    /// Prepares independent device correction resources on this renderer's device.
    public func prepareCorrection(_ correction: DeviceCorrection?, lut: LUTAsset? = nil) throws -> PreparedDeviceCorrection? {
        try encoder.prepareCorrection(correction, lut: lut)
    }

    /// Encodes a fixed style into the caller's command buffer without committing or waiting.
    ///
    /// Input pixels must already be orientation-normalized, opaque, display-referred SDR,
    /// with sRGB primaries and sRGB encoded values in a supported non-sRGB Metal format.
    /// `inputDescriptor` declares these facts; it does not perform color conversion.
    /// No metadata is read or returned by this overload.
    ///
    /// - Important: Consume or copy the result in the same command buffer before committing.
    ///   It may alias the input or pool storage recycled after completion. It is not an owned snapshot.
    /// - Throws: Invalid descriptors/options, incompatible devices/formats or GPU encoding failures.
    public func render(_ input: MTLTexture, style: PreparedCameraStyle,
                       inputDescriptor: InputDescriptor, options: RenderOptions = .init(),
                       correction: PreparedDeviceCorrection? = nil,
                       commandBuffer: MTLCommandBuffer) throws -> MTLTexture {
        try encoder.encode(input, style: style, correction: correction,
                           request: options.makeRequest(input: inputDescriptor), commandBuffer: commandBuffer)
    }

    /// Encodes evaluated dynamic-frame parameters. Has the same input and lifetime contract as
    /// the fixed-style texture overload. Parameters must belong to the supplied prepared definition.
    public func render(_ input: MTLTexture, style: PreparedStyleDefinition, parameters: FrameStyleParameters,
                       inputDescriptor: InputDescriptor, options: RenderOptions = .init(),
                       correction: PreparedDeviceCorrection? = nil,
                       commandBuffer: MTLCommandBuffer) throws -> MTLTexture {
        try encoder.encode(input, style: style, parameters: parameters, correction: correction,
                           request: options.makeRequest(input: inputDescriptor), commandBuffer: commandBuffer)
    }

    /// Releases idle rendering caches; does not invalidate completed native image outputs.
    public func releaseCaches() {
        encoder.releaseCaches()
        context.clearCaches()
    }
}
