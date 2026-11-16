import Foundation

/// A host-owned ceiling shared by all streams using the same ProcessingResources.
public struct ProcessingResourceLimits: Sendable, Equatable {
    public let maxResidentBytes: Int
    public init(maxResidentBytes: Int = 256 * 1024 * 1024) {
        self.maxResidentBytes = maxResidentBytes > 0 ? maxResidentBytes : 256 * 1024 * 1024
    }
}

public enum ProcessingBackpressure: Sendable { case reject, dropUnsubmitted }

/// Preferences, normalized by the resource manager. They never increase the host ceiling.
public struct ProcessingPolicy: Sendable, Equatable {
    public var maxResidentBytes: Int
    public var maxIdleBytes: Int
    public var maxInFlightFrames: Int
    public var maxPendingFrames: Int
    public var backpressure: ProcessingBackpressure
    public init(maxResidentBytes: Int = 256 * 1024 * 1024, maxIdleBytes: Int = 32 * 1024 * 1024,
                maxInFlightFrames: Int = 1, maxPendingFrames: Int = 1,
                backpressure: ProcessingBackpressure = .reject) {
        self.maxResidentBytes = maxResidentBytes; self.maxIdleBytes = maxIdleBytes
        self.maxInFlightFrames = maxInFlightFrames; self.maxPendingFrames = maxPendingFrames
        self.backpressure = backpressure
    }
    func normalized(limits: ProcessingResourceLimits) -> ProcessingPolicy {
        var value = self
        value.maxResidentBytes = min(limits.maxResidentBytes, maxResidentBytes > 0 ? maxResidentBytes : 256 * 1024 * 1024)
        value.maxIdleBytes = min(value.maxResidentBytes, max(0, maxIdleBytes))
        value.maxInFlightFrames = min(8, max(1, maxInFlightFrames))
        value.maxPendingFrames = min(8, max(0, maxPendingFrames))
        return value
    }
}

public struct ProcessingPolicyUpdate: Sendable {
    public let requested: ProcessingPolicy
    public let effective: ProcessingPolicy
    public let isShrinking: Bool
    /// Only newly encountered adjustments are reported; never emitted for each frame.
    public let warnings: [String]
}

public struct ProcessingResourceSnapshot: Sendable {
    public let residentBytes: Int
    public let idleBytes: Int
    public let activeFrames: Int
    public let allocationCount: Int
    public let effectivePolicy: ProcessingPolicy
    public var isShrinking: Bool { residentBytes > effectivePolicy.maxResidentBytes }
}

public enum FrameAdmissionIssue: String, Error, Sendable {
    case busy, notPrepared, budgetExhausted, closed, incompatibleResources
}
