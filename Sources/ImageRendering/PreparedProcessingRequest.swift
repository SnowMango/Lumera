import Foundation
import Metal
import ImagingCore

/// An immutable frame contract. Prepare a replacement when resource requirements change.
/// Standard textures contain opaque, orientation-normalized, encoded sRGB pixels.
public final class PreparedProcessingRequest: @unchecked Sendable {
    let observations: ObservationRequirements?
    public let requiresImageStaging: Bool
    public let input: InputDescriptor
    public let options: RenderOptions
    public let outputPixelFormat: MTLPixelFormat
    public let outputWidth: Int
    public let outputHeight: Int
    let parameters: StyleParameters
    let shape: ProcessingResourceShape
    let style: PreparedResolvedStyle
    let correction: PreparedDeviceCorrection?
    let request: RenderRequest
    let device: MTLDevice
    let renderer: LumeraRenderer
    public init(renderer: LumeraRenderer, style: PreparedResolvedStyle,
                input: InputDescriptor, options: RenderOptions = .init(),
                outputPixelFormat: MTLPixelFormat? = nil, requiresImageStaging: Bool = true, observations: ObservationRequirements? = nil, correction: PreparedDeviceCorrection? = nil) throws {
        let request = options.makeRequest(input: input)
        try request.validate()
        try TextureDimensions.validate(width: input.width, height: input.height, device: renderer.device)
        try PrecisionSafety.require(renderer.encoder.assessPrecision(style: style, correction: correction, request: request))
        let format = outputPixelFormat ?? renderer.imageInputFormat
        guard [.rgba16Float, .rgba32Float, .bgra8Unorm, .rgba8Unorm].contains(format),
              options.dynamicRange != .edr || [.rgba16Float, .rgba32Float].contains(format) else {
            throw LabError.unsupported("Unsupported explicit output format")
        }
        guard !(options.dynamicRange == .edr && renderer.imageInputFormat == .rgba32Float && format == .rgba16Float) else {
            throw LabError.unsupported("Float32 EDR output cannot be narrowed to Half without an output range proof")
        }
        let long = max(input.width, input.height), limit = min(options.maximumLongEdge ?? long, long)
        let ratio = Double(limit) / Double(long)
        outputWidth = max(1, Int(Double(input.width) * ratio)); outputHeight = max(1, Int(Double(input.height) * ratio))
        self.observations = observations
        self.requiresImageStaging = requiresImageStaging
        parameters = style.style.parameters
        shape = ProcessingResourceShape(parameters, style: style, correction: correction, request: request)
        self.renderer = renderer; device = renderer.device; self.style = style; self.input = input
        self.options = options; self.correction = correction; self.request = request; self.outputPixelFormat = format
    }
    // Time-varying seed/frame index do not change storage. Model parameter changes use
    // a new prepared request; the manager will reuse a compatible prepared arena later.
    public func frame(index: UInt32, seed: UInt32? = nil) throws -> PreparedProcessingRequest {
        var options = options; options.frameIndex = index; if let seed { options.seed = seed }
        return .init(copying: self, options: options)
    }
    private init(copying source: PreparedProcessingRequest, options: RenderOptions) {
        observations = source.observations
        requiresImageStaging = source.requiresImageStaging
        parameters = source.parameters; shape = source.shape
        renderer = source.renderer; device = source.device; style = source.style; correction = source.correction
        input = source.input; outputPixelFormat = source.outputPixelFormat
        outputWidth = source.outputWidth; outputHeight = source.outputHeight
        self.options = options; request = options.makeRequest(input: source.input)
    }
    /// Bind the existing resolved model decision to the explicit storage core.
    public init(plan: FrameRenderPlan, outputPixelFormat: MTLPixelFormat? = nil) throws {
        observations = nil
        requiresImageStaging = false
        try FrameEncoder(renderer: plan.model.renderer).validate(plan.input, plan: plan)
        renderer = plan.model.renderer; device = renderer.device; style = plan.style
        parameters = plan.controls.parameters; correction = plan.prefix; input = plan.request.input
        request = plan.request; self.outputPixelFormat = outputPixelFormat ?? renderer.imageInputFormat
        guard self.outputPixelFormat == renderer.imageInputFormat else { throw LabError.unsupported("Model target must match execution precision") }
        outputWidth = plan.model.execution.width; outputHeight = plan.model.execution.height
        var options = RenderOptions(maximumLongEdge: request.maximumLongEdge, seed: request.seed, frameIndex: request.frameIndex)
        options.dynamicRange = request.dynamicRange; options.inputValueBounds = request.inputValueBounds
        options.previewGlow = request.previewGlow; options.glowScale = request.glowScale
        options.halationScale = request.halationScale; options.softeningScale = request.softeningScale
        self.options = options
        shape = plan.configuration.shape
    }
    func matchesResources(_ other: PreparedProcessingRequest) -> Bool {
        var a = request, b = other.request
        a.frameIndex = 0; b.frameIndex = 0; a.seed = 0; b.seed = 0
        a.inputValueBounds = nil; b.inputValueBounds = nil
        return renderer === other.renderer && requiresImageStaging == other.requiresImageStaging && observations == other.observations && shape == other.shape && a == b && outputPixelFormat == other.outputPixelFormat
    }
}
