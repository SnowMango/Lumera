import Foundation
import ImagingCore

/// Caller-owned pure state shared by live sessions and replay.
public struct DecisionEngineState: Codable, Equatable, Sendable {
    /// 已完成时间适应的状态，包含持久锁和适应历史。
    public let adaptation: AdaptationState
    /// 上一次原始自动结果，未经时间适应或用户编辑，防止缺测回退反复平滑。
    public let fallback: FallbackSnapshot
    /// 产生该历史的有效输入配方摘要；更换配方必须重置历史。
    public let inputRecipeDigest: String
    public init(adaptation: AdaptationState, fallback: FallbackSnapshot, inputRecipeDigest: String) {
        self.adaptation = adaptation; self.fallback = fallback; self.inputRecipeDigest = inputRecipeDigest
    }
}
/// 一步决策及其后继状态；调用方决定何时提交状态，纯计算本身不修改会话。
public struct DecisionStepResult: Sendable {
    public let decision: FrameDecision
    public let state: DecisionEngineState
    public init(decision: FrameDecision, state: DecisionEngineState) { self.decision = decision; self.state = state }
}
/// Pure automatic replay. Descriptor identity is checked; no GPU resources are loaded.
public enum DecisionReplay {
    /// 按给定顺序从空历史重放整段记录；reset 事件在段内建立新的历史边界。
    /// 仅返回参数决策，不解码图像或执行像素渲染。
    public static func evaluate(_ records: [DecisionRecord], model: CompiledCameraModel) throws -> [FrameDecision] {
        var state: DecisionEngineState?
        return try records.map { record in
            let result = try step(record, model: model, state: state)
            state = result.state
            return result.decision
        }
    }

    /// Automatic controls adapt before user edits. Unlock plus strength/visual offsets
    /// is unsupported until automatic and final edit coordinates have an explicit mapping.
    /// 校验模型、资源及当前输入事实后，执行自动求值 → 时间适应 → 用户编辑。
    /// 显式提供的 fallback 必须与可重建历史一致；失败不会改变传入状态。
    public static func step(_ record: DecisionRecord, model: CompiledCameraModel, state: DecisionEngineState? = nil) throws -> DecisionStepResult {
        let resourceDigest = Digest.data(try JSON.encode(model.definition.appearance.resources))
        guard record.version == 1, record.modelDigest == model.identity,
              record.resourceDigest == resourceDigest, let current = record.currentInput else {
            throw LabError.unsupported("Replay requires matching version, identities and current input facts")
        }
        try current.validate()
        guard current.stamp == record.context.evaluationStamp, current.effectiveRecipeDigest == record.inputRecipeDigest else {
            throw LabError.invalid("Replay input identity mismatch")
        }
        // reset 先丢弃旧历史，避免 seek/换源后的首帧读取旧 fallback。
        let previous: DecisionEngineState?
        if case .reset = record.event { previous = nil } else { previous = state }
        if let previous {
            guard previous.inputRecipeDigest == record.inputRecipeDigest,
                  previous.fallback.stamp == previous.adaptation.stamp,
                  previous.fallback.controls.modelID == previous.adaptation.controls.modelID,
                  previous.fallback.controls.sourceID == previous.adaptation.controls.sourceID,
                  previous.fallback.controls.calibrationID == previous.adaptation.controls.calibrationID,
                  previous.fallback.controls.featureDigest == previous.adaptation.controls.featureDigest else {
                throw LabError.invalid("Recipe changed or decision history is inconsistent")
            }
        }
        try ObservationValidity.validate(record.context.observations, current: current, requirements: model.definition.observations)
        var context = record.context
        if let supplied = context.fallback, supplied != previous?.fallback { throw LabError.invalid("Replay fallback disagrees with reconstructed history") }
        context.fallback = previous?.fallback
        var declaredLocks = previous?.adaptation.locks ?? []
        var unlocks: [ControlOverride] = []
        switch record.event {
        case .lock(let values):
            for value in values {
                guard model.definition.edits.overrideTargets.contains(value.target) else { throw LabError.invalid("Unsupported replay lock target") }
                declaredLocks.removeAll { $0.target == value.target }; declaredLocks.append(value)
            }
        case .unlock(let values):
            unlocks = values
            guard record.edits.strength == nil, record.edits.visualOffsets.allSatisfy({ $0.value == 0 }),
                  !record.edits.overrides.contains(where: { override in values.contains(where: { $0.target == override.target }) }) else {
                throw LabError.unsupported("Unlock with strength, visual offsets or an override of the unlocked target is unsupported")
            }
            for value in values { declaredLocks.removeAll { $0.target == value.target } }
        default: break
        }
        guard record.edits.locks.allSatisfy({ declaredLocks.contains($0) }) else {
            throw LabError.invalid("Replay lock edits require a matching recorded lock event")
        }
        let automatic = try CameraModelEvaluator.evaluate(model, context: context, lockedControls: declaredLocks + unlocks)
        let adapted = try AdaptationReducer.reduce(automatic, state: previous?.adaptation, stamp: current.stamp,
                                                   event: record.event, policy: model.definition.adaptation)
        var edits = record.edits
        // Persistent locks and unlock's continuity frame are final-value constraints.
        edits.locks = adapted.state.locks + unlocks
        var resolved = try EditResolver.resolve(edits, automatic: adapted.controls, model: model)
        resolved.lockedTargets = adapted.state.locks.map(\.target)
        resolved.diagnostics += adapted.controls.diagnostics
        let decision = FrameDecision(stamp: current.stamp, modelDigest: model.identity, inputDigest: current.inputID,
                                     resourceDigest: resourceDigest, observations: context.observations,
                                     edits: record.edits, controls: resolved, seed: record.seed)
        // 保存 automatic 而非 adapted.controls，确保缺测历史与时间适应历史相互独立。
        let next = DecisionEngineState(adaptation: adapted.state, fallback: .init(controls: automatic, stamp: current.stamp),
                                       inputRecipeDigest: record.inputRecipeDigest)
        return .init(decision: decision, state: next)
    }
}
