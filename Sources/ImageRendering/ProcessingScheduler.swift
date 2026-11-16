import Foundation
import ImagingCore

/// Bounded admission. Pending replacement cancels only work that has not started.
/// Running slots are held through callback delivery, including a slow delivery queue.
final class ProcessingScheduler: @unchecked Sendable {
    private struct Job { let task: FrameTask; let run: () -> Void }
    private let lock = UnfairLock()
    private let policy: () -> ProcessingPolicy
    private var active = Set<ObjectIdentifier>()
    private var pending: [Job] = []
    init(policy: @escaping () -> ProcessingPolicy) { self.policy = policy }
    func accept(_ task: FrameTask, claim: () -> Bool, run: @escaping () -> Void) -> FrameAdmissionIssue? {
        var start: Job?, replaced: Job?
        let issue: FrameAdmissionIssue? = lock.withLock {
            let p = policy()
            let available = active.count < p.maxInFlightFrames
            if !available && pending.count >= p.maxPendingFrames &&
                (p.backpressure != .dropUnsubmitted || pending.isEmpty) { return .busy }
            guard claim() else { return .incompatibleResources }
            let job = Job(task: task, run: run)
            if available { active.insert(ObjectIdentifier(task)); start = job }
            else {
                if pending.count >= p.maxPendingFrames { replaced = pending.removeFirst() }
                pending.append(job)
            }
            return nil
        }
        // Running a cancelled job only delivers its cancellation; it cannot encode or submit.
        if let replaced { replaced.task.cancel(); replaced.run() }
        start?.run()
        return issue
    }
    func finish(_ task: FrameTask) {
        let next: [Job] = lock.withLock {
            active.remove(ObjectIdentifier(task))
            var result: [Job] = []
            while active.count < policy().maxInFlightFrames && !pending.isEmpty {
                let job = pending.removeFirst(); active.insert(ObjectIdentifier(job.task)); result.append(job)
            }
            return result
        }
        next.forEach { $0.run() }
    }
}
