import Foundation
import ImagingCore
import ImageRendering

/// wait 有界等待空位；dropUnsubmitted 替换最早待提交帧，仅 active 占满时丢弃新帧。
public enum SessionBackpressure: Sendable { case wait, dropUnsubmitted }
/// 输出未交付的原因；丢帧结果保留源时间戳，不伪造连续帧序号。
public enum FrameDropReason: String, Sendable { case backpressure, cancelled, reset, gpuFailure }
/// 成功时持有完成的输出；背压、取消或重置时明确返回原帧与原因。
public enum FrameOutcome: Sendable {
    case rendered(RenderedFrame)
    case dropped(FrameStamp, FrameDropReason)
}

/// Cancellation is synchronized with the actual commit boundary, not an actor hop.
final class SessionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var submitted = false
    private var preparation: Task<PreparedInput, Error>?
    func cancel() {
        lock.lock(); cancelled = true; let preparation = preparation; lock.unlock()
        preparation?.cancel()
    }
    func trackPreparation(_ task: Task<PreparedInput, Error>) {
        lock.lock(); preparation = task; let shouldCancel = cancelled; lock.unlock()
        if shouldCancel { task.cancel() }
    }
    func clearPreparation() { lock.lock(); preparation = nil; lock.unlock() }
    func check() throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
    }
    // 与取消共用锁的提交前检查；必须由驱动在实际 command buffer.commit 前同步调用。
    func markSubmitted() throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        submitted = true
    }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

struct SessionRenderResult: Sendable {
    let frame: RenderedFrame
    let observations: FrameObservations?
}
/// 一次已经提交的工作；等待完成不会因调用方取消而提前释放 GPU 使用中的资源。
struct SessionSubmission: @unchecked Sendable {
    let completion: () async throws -> SessionRenderResult
    func value() async throws -> SessionRenderResult { try await completion() }
}
/// 可注入的观察/提交边界；测试可控制调度，生产路径仍委托唯一的 LumeraRenderer。
struct SessionRenderDriver: @unchecked Sendable {
    var observe: (PreparedInput, FrameStamp, ObservationRequirements, Int) async throws -> FrameObservations
    var submit: (PreparedInput, FrameRenderPlan, ObservationRequirements?, () throws -> Void) throws -> SessionSubmission
    /// observe 可以单独提交统计；submit 可将本帧统计与效果放入同一命令缓冲。
    static func live(_ renderer: LumeraRenderer) -> Self {
        .init(observe: { input, stamp, requirements, bytes in
            try await renderer.observe(input, stamp: stamp, requirements: requirements, maxResidentBytes: bytes)
        }, submit: { input, plan, observations, beforeCommit in
            let submitted = try renderer.submit(input, plan: plan, observations: observations, beforeCommit: beforeCommit)
            return .init(completion: {
                let result = try await submitted.value()
                return .init(frame: result.frame, observations: result.observations)
            })
        })
    }
}

/// Source order is independent of queue position and output delivery.
struct SessionOrder {
    private var last: FrameStamp?
    // 接收顺序与队列是否最终提交分离；丢帧不会回滚这里的序号/PTS。
    mutating func accept(_ stamp: FrameStamp) throws {
        try stamp.validate()
        if let last {
            guard stamp.streamID == last.streamID, stamp.generation == last.generation,
                  stamp.index > last.index, stamp.presentationTime > last.presentationTime else {
                throw LabError.invalid("Duplicate, reverse or changed source generation requires session reset")
            }
        }
        last = stamp
    }
    mutating func reset() { last = nil }
}
