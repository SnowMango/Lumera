import Metal
import ImagingCore

/// Derived data only: no current input, range, frame stamp, lease or claim state.
final class PreparedRenderConfiguration {
    let style: PreparedResolvedStyle
    let prefix: PreparedDeviceCorrection?
    let shape: ProcessingResourceShape
    let request: RenderRequest
    init(parameters: StyleParameters, style: PreparedResolvedStyle, prefix: PreparedDeviceCorrection?, request: RenderRequest) {
        self.style = style; self.prefix = prefix
        var template = request; template.inputValueBounds = nil; template.frameIndex = 0; template.seed = 42
        self.request = template
        shape = ProcessingResourceShape(parameters, style: style, correction: prefix, request: template)
    }
}

struct RenderConfigurationKey: Equatable {
    let parameters: StyleParameters
    let weights: [ResourceWeight]
    let exposure: Double
    let whiteBalance: WhiteBalanceCorrection?
    let width: Int, height: Int
    let format: MTLPixelFormat
    init(_ controls: ResolvedControls, input: PreparedInput) {
        parameters = controls.parameters; weights = controls.lutWeights
        exposure = controls.inputExposureEV; whiteBalance = controls.inputWhiteBalance
        width = input.width; height = input.height; format = input.texture.pixelFormat
    }
}

extension PreparedStyleModel {
    func renderConfiguration(for controls: ResolvedControls, input: PreparedInput) throws -> PreparedRenderConfiguration {
        let key = RenderConfigurationKey(controls, input: input)
        if let cached = configurationLock.withLock({ renderConfigurationCache }), cached.key == key { return cached.value }
        let active = controls.lutWeights.filter { $0.weight > 0 }
        let style: PreparedResolvedStyle
        if active.isEmpty { style = base }
        else {
            let selected = try active.map { weight -> PreparedResolvedStyle in
                guard compiled.lutResourceIDs.contains(weight.resourceID), let resident = lutStyles[weight.resourceID] else {
                    throw LabError.invalid("LUT is outside the prepared palette")
                }
                return resident
            }
            style = try renderer.encoder.blendStyle(base: base, styles: selected, weights: active.map(\.weight))
        }
        var color = ColorResponse(); color.exposureEV = controls.inputExposureEV
        if let white = controls.inputWhiteBalance { color.whiteBalance = white }
        let prefix = try PreparedDeviceCorrection.inputEdit(color, device: renderer.device)
        var request = RenderRequest(input: .init(width: input.width, height: input.height),
                                    maximumLongEdge: max(execution.width, execution.height))
        request.dynamicRange = execution.dynamicRange == .edr ? .edr : .sdr
        let effects = try execution.effectResolutions()
        request.glowScale = effects.glow; request.halationScale = effects.halation; request.softeningScale = effects.softening
        request.previewGlow = execution.previewGlow
        let value = PreparedRenderConfiguration(parameters: controls.parameters, style: style, prefix: prefix, request: request)
        return configurationLock.withLock {
            if let cached = renderConfigurationCache, cached.key == key { return cached.value }
            renderConfigurationCache = (key, value)
            return value
        }
    }
}
