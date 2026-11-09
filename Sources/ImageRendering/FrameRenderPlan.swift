import Foundation
import ImagingCore

/// 将已求值的控制量绑定到特定输入、模型及帧预算的一次性执行计划。
public final class FrameRenderPlan: @unchecked Sendable {
    public let controls: ResolvedControls
    public let inputID: String
    public let stamp: FrameStamp?
    public let model: PreparedCameraModel
    let input: PreparedInput
    let style: PreparedCameraStyle
    let prefix: PreparedDeviceCorrection?
    let request: RenderRequest
    let lease: FrameBudgetLease
    let workingSet: TileWorkingSet
    private let lock = NSLock()
    private var used = false
    var hasBeenClaimed: Bool { lock.lock(); defer { lock.unlock() }; return used }
    init(controls: ResolvedControls, input: PreparedInput, model: PreparedCameraModel, style: PreparedCameraStyle,
         prefix: PreparedDeviceCorrection?, request: RenderRequest, stamp: FrameStamp?, lease: FrameBudgetLease, workingSet: TileWorkingSet) {
        self.controls = controls; self.input = input; inputID = input.inputID; self.model = model; self.style = style
        self.prefix = prefix; self.request = request; self.stamp = stamp; self.lease = lease; self.workingSet = workingSet
    }
    /// 放弃尚未领取的计划，归还帧槽和临时预算。已领取的计划由编码或提交路径负责收尾。
    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        guard !used else { return }; used = true; lease.completeGPU()
    }
    func claim() throws { lock.lock(); defer { lock.unlock() }; guard !used else { throw LabError.invalid("Frame plan already encoded") }; used = true }
}
