import Foundation
import Metal
import ImagingCore

/// Reservation precedes allocation. Every owner, including retired frames, keeps its charge.
final class ProcessingResourceLedger: @unchecked Sendable {
    private let lock = UnfairLock()
    let limits: ProcessingResourceLimits
    private var current: ProcessingPolicy
    private var bytes = 0
    private var idle = 0
    private var owners: [WeakProcessingResources] = []
    var idleBytes: Int { lock.withLock { idle } }
    func changeIdle(by delta: Int) { lock.withLock { idle += delta } }
    func registerOwner(_ owner: ProcessingResources) { lock.withLock {
        owners.removeAll { $0.value == nil }; owners.append(WeakProcessingResources(owner))
    } }
    func clearOwners() {
        let currentOwners = lock.withLock { owners.compactMap(\.value) }
        currentOwners.forEach { $0.clearIdleResources() }
    }
    func trimOwners() {
        let currentOwners = lock.withLock { owners.compactMap(\.value) }
        currentOwners.forEach { $0.trimSharedIdle() }
    }
    private var allocations = 0
    private var registered: [ProcessingStorageIdentity: WeakProcessingCharge] = [:]
    private var warnings = Set<String>()
    private var adjustments: [String] = []
    var policyWarnings: [String] { lock.withLock { adjustments } }
    func retainPreparedBytes(_ count: Int) {
        lock.withLock {
            if current.maxIdleBytes > 0 && count > current.maxIdleBytes {
                current.maxIdleBytes = min(count, current.maxResidentBytes)
                adjustments = ["maxIdleBytes adjusted to retain the prepared working set: \(current.maxIdleBytes)"]
            }
        }
    }
    init(limits: ProcessingResourceLimits, policy: ProcessingPolicy) {
        self.limits = limits; current = policy.normalized(limits: limits)
    }
    var policy: ProcessingPolicy { lock.withLock { current } }
    var residentBytes: Int { lock.withLock { bytes } }
    var allocationCount: Int { lock.withLock { allocations } }
    func update(_ requested: ProcessingPolicy) -> ProcessingPolicyUpdate {
        lock.withLock {
            current = requested.normalized(limits: limits)
            var changes: [String] = []
            for (key, a, b) in [("maxResidentBytes", requested.maxResidentBytes, current.maxResidentBytes),
                               ("maxIdleBytes", requested.maxIdleBytes, current.maxIdleBytes),
                               ("maxInFlightFrames", requested.maxInFlightFrames, current.maxInFlightFrames),
                               ("maxPendingFrames", requested.maxPendingFrames, current.maxPendingFrames)] where a != b {
                let message = "\(key): \(a) → \(b)"
                if warnings.insert(message).inserted { changes.append(message) }
            }
            // Bound the diagnostic history even if a producer sends a different invalid value each time.
            if warnings.count > 32 { warnings.removeAll(keepingCapacity: true) }
            return .init(requested: requested, effective: current, isShrinking: bytes > current.maxResidentBytes, warnings: changes)
        }
    }
    func reserve(_ count: Int, adaptingPolicy: Bool = false) throws -> ProcessingResourceCharge {
        try lock.withLock {
            if adaptingPolicy, count >= 0, bytes <= limits.maxResidentBytes,
               count <= limits.maxResidentBytes - bytes, bytes + count > current.maxResidentBytes {
                current.maxResidentBytes = bytes + count
                adjustments = ["maxResidentBytes adjusted to fit prepared resources: \(current.maxResidentBytes)"]
            }
            guard count >= 0, bytes <= current.maxResidentBytes,
                  count <= current.maxResidentBytes - bytes else { throw FrameAdmissionIssue.budgetExhausted }
            bytes += count
            return ProcessingResourceCharge(owner: self, bytes: count)
        }
    }
    func register(_ texture: MTLTexture, charge: ProcessingResourceCharge) {
        lock.withLock {
            registered = registered.filter { $0.value.value != nil }
            registered[.texture(texture)] = WeakProcessingCharge(charge)
        }
    }
    func borrow(identity: ProcessingStorageIdentity, bytes count: Int, adaptingPolicy: Bool = false) throws -> ProcessingResourceCharge {
        try lock.withLock {
            if let existing = registered[identity]?.value { return existing }
            if adaptingPolicy, count >= 0, bytes <= limits.maxResidentBytes,
               count <= limits.maxResidentBytes - bytes { current.maxResidentBytes = max(current.maxResidentBytes, bytes + count) }
            guard count >= 0, bytes <= current.maxResidentBytes, count <= current.maxResidentBytes - bytes else {
                throw FrameAdmissionIssue.budgetExhausted
            }
            bytes += count
            let charge = ProcessingResourceCharge(owner: self, bytes: count)
            registered = registered.filter { $0.value.value != nil }
            registered[identity] = WeakProcessingCharge(charge)
            return charge
        }
    }
    fileprivate func resize(from old: Int, to new: Int) throws {
        try lock.withLock {
            guard new >= 0 else { throw FrameAdmissionIssue.budgetExhausted }
            if new > old {
                guard bytes <= current.maxResidentBytes, new - old <= current.maxResidentBytes - bytes else {
                    throw FrameAdmissionIssue.budgetExhausted
                }
            }
            bytes += new - old
        }
    }
    func didAllocate() { lock.withLock { allocations += 1 } }
    fileprivate func release(_ count: Int) { lock.withLock { bytes -= count } }
}

final class ProcessingResourceCharge: @unchecked Sendable {
    private let owner: ProcessingResourceLedger
    private(set) var bytes: Int
    init(owner: ProcessingResourceLedger, bytes: Int) { self.owner = owner; self.bytes = bytes }
    // Only the allocating thread mutates a charge before publishing its resource.
    func reconcile(_ actual: Int) throws { try owner.resize(from: bytes, to: actual); bytes = actual }
    deinit { owner.release(bytes) }
}

private final class WeakProcessingResources {
    weak var value: ProcessingResources?
    init(_ value: ProcessingResources) { self.value = value }
}
