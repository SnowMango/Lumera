import Foundation
import Metal
import ImagingCore

/// 将已解析的控制量和兼容的输入、模型组合成可编码的帧计划。
public struct RenderPlanner {
    public init() {}
    /// 验证身份、资格与输出几何，并领取帧预算。可接收同一模型预先取得的帧预留。
    public func plan(_ controls: ResolvedControls, input: PreparedInput, model: PreparedStyleModel,
                     stamp: FrameStamp? = nil, seed: UInt32 = 42, reservation: FrameReservation? = nil) throws -> FrameRenderPlan {
        try controls.parameters.validate(resolved: true); try ResourceWeight.validate(controls.lutWeights)
        guard controls.automatic.modelID == model.compiled.identity, controls.automatic.sourceID == input.sourceID,
              controls.automatic.calibrationID == input.calibrationID, controls.automatic.featureDigest == model.compiled.featureDigest,
              input.texture.device.registryID == model.renderer.device.registryID,
              input.execution.precision == model.execution.precision, input.execution.dynamicRange == model.execution.dynamicRange else { throw LabError.invalid("Frame controls, model and input identities differ") }
        let compatibility = model.compiled.definition.compatibility
        guard compatibility.referenceRenditionIDs.isEmpty || compatibility.referenceRenditionIDs.contains(input.working.referenceRenditionID),
              Set(compatibility.requiredQualifications).isSubset(of: Set(input.qualifications.map(\.domain))) else { throw LabError.invalid("Input reference or qualification is incompatible") }
        let ratio = min(1, Double(max(model.execution.width, model.execution.height)) / Double(max(input.width, input.height)))
        guard max(1, Int(Double(input.width) * ratio)) == model.execution.width,
              max(1, Int(Double(input.height) * ratio)) == model.execution.height else {
            throw LabError.invalid("Requested output geometry must match aspect-preserving input scaling")
        }
        let active = controls.lutWeights.filter { $0.weight > 0 }
        let style: PreparedResolvedStyle
        if active.isEmpty { style = model.base }
        else {
            let selected = try active.map { weight -> PreparedResolvedStyle in
                guard model.compiled.lutResourceIDs.contains(weight.resourceID), let resident = model.lutStyles[weight.resourceID] else { throw LabError.invalid("LUT is outside the prepared palette") }; return resident
            }
            style = try model.renderer.encoder.blendStyle(base: model.base, styles: selected, weights: active.map(\.weight))
        }
        var inputColor = ColorResponse(); inputColor.exposureEV = controls.inputExposureEV
        if let wb = controls.inputWhiteBalance { inputColor.whiteBalance = wb }
        let prefix = try PreparedDeviceCorrection.inputEdit(inputColor, device: model.renderer.device)
        let residentInput = reservation?.residentInput
        if let residentInput, residentInput.input !== input {
            throw LabError.invalid("Photo reservation belongs to another input")
        }
        let retainedInputBytes = residentInput == nil ? input.residentStorageBytes : 0
        let lease: FrameBudgetLease
        if let reservation {
            guard reservation.model === model else { throw LabError.invalid("Frame reservation belongs to another model") }
            try reservation.issue(inputBytes: retainedInputBytes); lease = reservation.lease
        } else { lease = try model.budget.acquire(retainedInputBytes: retainedInputBytes) }
        let workingSet = TileWorkingSet(limit: reservation?.execution.budget.maxResidentBytes ?? lease.allowance)
        try workingSet.reserve(retainedInputBytes)
        var request = RenderRequest(input: .init(width: input.width, height: input.height), maximumLongEdge: max(model.execution.width, model.execution.height))
        // 输出只做等比缩小，所选执行尺寸须与上面的几何检查一致。
        request.dynamicRange = model.execution.dynamicRange == .edr ? .edr : .sdr
        request.inputValueBounds = input.valueBounds; request.seed = seed
        let effects = try model.execution.effectResolutions()
        request.glowScale = effects.glow; request.halationScale = effects.halation; request.softeningScale = effects.softening
        request.previewGlow = model.execution.previewGlow
        if let stamp { try stamp.validate(); request.frameIndex = UInt32(truncatingIfNeeded: stamp.index) }
        return FrameRenderPlan(controls: controls, input: input, model: model, style: style, prefix: prefix, request: request, stamp: stamp, lease: lease, workingSet: workingSet, residentInput: residentInput)
    }
}
