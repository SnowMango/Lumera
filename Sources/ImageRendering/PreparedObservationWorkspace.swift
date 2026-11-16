import Metal
import ImagingCore

/// Per-slot statistics storage. It is never shared by simultaneous frames.
final class PreparedObservationWorkspace: @unchecked Sendable {
    let samples: MTLBuffer
    let partials: MTLBuffer
    let output: MTLBuffer
    let width: Int, height: Int, featureCount: Int
    private let lock = UnfairLock()
    private var claimed = false
    func acquire(retaining input: PreparedInput) throws -> ObservationWorkspaceLease {
        try lock.withLock {
            guard !claimed else { throw FrameAdmissionIssue.busy }
            claimed = true
            return ObservationWorkspaceLease(owner: self, input: input)
        }
    }
    fileprivate func release() { lock.withLock { claimed = false } }
    private let charges: [ProcessingResourceCharge]
    var bytes: Int { charges.reduce(0) { $0 + $1.bytes } }
    init(device: MTLDevice, width fullWidth: Int, height fullHeight: Int,
         requirements: ObservationRequirements, ledger: ProcessingResourceLedger) throws {
        try requirements.validate()
        featureCount = requirements.features.count
        guard featureCount > 0, featureCount <= 64,
              requirements.features.allSatisfy({ $0.samplingLongEdge == 256 }) else {
            throw LabError.unsupported("Unsupported observation workspace")
        }
        let scale = min(1, 256 / Double(max(fullWidth, fullHeight)))
        width = max(1, Int((Double(fullWidth) * scale).rounded(.down)))
        height = max(1, Int((Double(fullHeight) * scale).rounded(.down)))
        let count = width * height, bytes = (262 + featureCount) * 4
        var reserved: [ProcessingResourceCharge] = []
        func allocate(_ length: Int, _ options: MTLResourceOptions) throws -> MTLBuffer {
            let estimate = device.heapBufferSizeAndAlign(length: length, options: options).size
            let charge = try ledger.reserve(estimate, adaptingPolicy: true)
            guard let buffer = device.makeBuffer(length: length, options: options) else { throw LabError.io("Cannot prepare statistics storage") }
            try charge.reconcile(max(estimate, buffer.allocatedSize))
            reserved.append(charge); ledger.didAllocate(); return buffer
        }
        samples = try allocate(count * 16, .storageModePrivate)
        partials = try allocate(((count + 255) / 256) * bytes, .storageModePrivate)
        output = try allocate(bytes, .storageModeShared)
        charges = reserved
    }
}

final class ObservationWorkspaceLease {
    private let owner: PreparedObservationWorkspace
    private let input: PreparedInput
    init(owner: PreparedObservationWorkspace, input: PreparedInput) { self.owner = owner; self.input = input }
    deinit { owner.release() }
}
