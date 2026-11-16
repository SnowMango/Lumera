import Foundation
import Metal
import ObjectiveC
import ImagingCore

private var processingCommandOwnerKey: UInt8 = 0

/// The command owns this guard even if encoding fails or its returned handle is dropped.
/// This object deliberately never holds the command itself.
final class ProcessingCommandOwner: @unchecked Sendable {
    private let lock = UnfairLock()
    private var retained: [AnyObject]
    init(_ retained: [AnyObject]) { self.retained = retained }
    func finish() {
        let released = lock.withLock { let value = retained; retained = []; return value }
        withExtendedLifetime(released) {}
    }
    static func attach(to command: MTLCommandBuffer, retaining resources: [AnyObject]) -> ProcessingCommandOwner {
        // A command may contain multiple frame encodings. Chain owners, not commands.
        var resources = resources
        if let previous = objc_getAssociatedObject(command, &processingCommandOwnerKey) as? ProcessingCommandOwner {
            resources.append(previous)
        }
        let owner = ProcessingCommandOwner(resources)
        objc_setAssociatedObject(command, &processingCommandOwnerKey, owner, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        command.addCompletedHandler { _ in owner.finish() }
        return owner
    }
}

/// External encoding handle. Append downstream commands, then commit exactly once.
/// Abandoning does not release referenced storage while the command remains alive.
public final class FrameEncodingLease: @unchecked Sendable {
    private weak var command: MTLCommandBuffer?
    private let lock = UnfairLock()
    private var finished = false
    init(command: MTLCommandBuffer) { self.command = command }
    public func commit() throws {
        try lock.withLock {
            guard !finished, let command, command.status == .notEnqueued else {
                throw LabError.invalid("Encoding lease is no longer submittable")
            }
            finished = true; command.commit()
        }
    }
    /// Drop the unsubmitted command after this call. Its destruction releases the guard.
    public func abandon() { lock.withLock { finished = true } }
}
