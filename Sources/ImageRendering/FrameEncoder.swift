import Foundation
import Metal
import ImagingCore

/// 将一次性帧计划编码到调用方提供的 Metal 命令缓冲区。
public struct FrameEncoder {
    private let renderer: LumeraRenderer
    public init(renderer: LumeraRenderer) { self.renderer = renderer }
    /// 使用同设备、尚未入队且保留资源引用的命令缓冲区。提交前在同一缓冲区内编码后续读取或独立副本。
    public func encode(_ input: PreparedInput, plan: FrameRenderPlan, commandBuffer: MTLCommandBuffer) throws -> EncodedFrame {
        try encode(input, plan: plan, commandBuffer: commandBuffer, alreadyClaimed: false)
    }
    func encode(_ input: PreparedInput, plan: FrameRenderPlan, commandBuffer: MTLCommandBuffer, alreadyClaimed: Bool) throws -> EncodedFrame {
        guard plan.inputID == input.inputID, plan.model.renderer === renderer else { throw LabError.invalid("Frame plan belongs to another input or renderer") }
        guard commandBuffer.status == .notEnqueued, commandBuffer.retainedReferences,
              commandBuffer.device.registryID == renderer.device.registryID else { throw LabError.invalid("Frame encoding requires an unsubmitted retained command on the model device") }
        try plan.request.validate(); try plan.controls.parameters.validate(resolved: true)
        try renderer.encoder.checkModelSafety(style: plan.style, parameters: plan.controls.parameters, prefix: plan.prefix, request: plan.request)
        if !alreadyClaimed { try plan.claim() }
        commandBuffer.addCompletedHandler { [plan] _ in plan.lease.completeGPU() }
        let texture = try renderer.encoder.encodeModel(input.texture, style: plan.style, parameters: plan.controls.parameters,
            prefix: plan.prefix, request: plan.request, workingSet: plan.workingSet, commandBuffer: commandBuffer)
        return EncodedFrame(texture: texture, input: input, plan: plan, command: commandBuffer, renderer: renderer)
    }
}
/// 借用的帧结果，纹理可能与输入或临时工作纹理共用存储。
public final class EncodedFrame: @unchecked Sendable {
    public let texture: MTLTexture
    let input: PreparedInput
    let plan: FrameRenderPlan
    let command: MTLCommandBuffer
    let renderer: LumeraRenderer
    private let lock = NSLock()
    private var copied = false
    init(texture: MTLTexture, input: PreparedInput, plan: FrameRenderPlan, command: MTLCommandBuffer, renderer: LumeraRenderer) {
        self.texture = texture; self.input = input; self.plan = plan; self.command = command; self.renderer = renderer
    }
    /// 在原命令缓冲区中编码独立副本，每个借用结果最多一次。副本计入当前帧预算。
    public func copyOwned(commandBuffer: MTLCommandBuffer) throws -> FrameReadback {
        lock.lock(); defer { lock.unlock() }
        guard commandBuffer === command, command.status == .notEnqueued, !copied else { throw LabError.invalid("Owned output must be copied once in the original command") }
        let owned = try renderer.copyOwned(texture, commandBuffer: command, workingSet: plan.workingSet)
        try plan.lease.retainOutput(bytes: owned.allocatedSize)
        retainOutputLease(on: owned, lease: plan.lease)
        copied = true
        return FrameReadback(texture: owned, input: input, plan: plan, command: command)
    }
}
/// 持有独立副本及其原始命令缓冲区的读取凭据。
public final class FrameReadback: @unchecked Sendable {
    private let texture: MTLTexture
    private let input: PreparedInput
    private let plan: FrameRenderPlan
    private let command: MTLCommandBuffer
    init(texture: MTLTexture, input: PreparedInput, plan: FrameRenderPlan, command: MTLCommandBuffer) {
        self.texture = texture; self.input = input; self.plan = plan; self.command = command
    }
    /// 在 GPU 成功完成后取得帧，调用方负责提交和等待。
    public func resolve() throws -> RenderedFrame {
        guard command.status == .completed, command.error == nil else { throw LabError.invalid("Rendered output requires successful GPU completion") }
        return RenderedFrame(texture: texture, input: input, plan: plan)
    }
}
