import Metal
import ImagingCore

final class ProcessingBufferStorage: @unchecked Sendable {
    let buffer: MTLBuffer
    let options: MTLResourceOptions
    let charge: ProcessingResourceCharge
    init(device: MTLDevice, length: Int, options: MTLResourceOptions, ledger: ProcessingResourceLedger) throws {
        guard length > 0, length <= device.maxBufferLength else { throw LabError.invalid("Invalid range buffer length") }
        self.options = options
        let estimate = device.heapBufferSizeAndAlign(length: length, options: options).size
        charge = try ledger.reserve(estimate)
        guard let buffer = device.makeBuffer(length: length, options: options) else { throw LabError.io("Cannot allocate range buffer") }
        try charge.reconcile(max(estimate, buffer.allocatedSize))
        self.buffer = buffer; ledger.didAllocate()
    }
}

/// Shared by the command's retention and CPU readback. Last owner returns storage.
final class ProcessingBufferLease: @unchecked Sendable {
    private let storage: ProcessingBufferStorage
    private let recycle: (ProcessingBufferStorage) -> Void
    var buffer: MTLBuffer { storage.buffer }
    var bytes: Int { storage.charge.bytes }
    init(storage: ProcessingBufferStorage, recycle: @escaping (ProcessingBufferStorage) -> Void) {
        self.storage = storage; self.recycle = recycle
    }
    deinit { recycle(storage) }
}

/// The command owns this holder until completion or command destruction, not vice versa.
final class RangeCommandBuffers: @unchecked Sendable {
    private let lock = UnfairLock()
    private var leases: [ProcessingBufferLease] = []
    func retain(_ lease: ProcessingBufferLease) { lock.withLock { leases.append(lease) } }
    func complete() {
        let released = lock.withLock { () -> [ProcessingBufferLease] in
            let old = leases; leases.removeAll(); return old
        }
        withExtendedLifetime(released) {}
    }
}
