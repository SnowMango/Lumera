import Foundation
import Metal
import ImagingCore

final class ProcessingTextureStorage: @unchecked Sendable {
    let texture: MTLTexture
    let charge: ProcessingResourceCharge
    init(device: MTLDevice, width: Int, height: Int, format: MTLPixelFormat,
         ledger: ProcessingResourceLedger) throws {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        d.storageMode = .private; d.usage = [.shaderRead, .shaderWrite, .pixelFormatView]
        let estimate = device.heapTextureSizeAndAlign(descriptor: d).size
        charge = try ledger.reserve(estimate, adaptingPolicy: true)
        guard let texture = device.makeTexture(descriptor: d) else { throw LabError.io("Cannot allocate prepared frame storage") }
        try charge.reconcile(max(estimate, texture.allocatedSize))
        self.texture = texture; ledger.didAllocate(); ledger.register(texture, charge: charge)
    }
}

final class ProcessingWorkspaceStorage: @unchecked Sendable {
    let input: ProcessingTextureStorage?
    let observations: PreparedObservationWorkspace?
    let arena: Arena
    let prepared: PreparedProcessingRequest
    let ledger: ProcessingResourceLedger
    var bytes: Int { (input?.charge.bytes ?? 0) + arena.allocatedBytes + (observations?.bytes ?? 0) }
    init(request: PreparedProcessingRequest, output: MTLTexture, ledger: ProcessingResourceLedger, preparationInput externalInput: MTLTexture? = nil) throws {
        self.ledger = ledger; prepared = request
        if request.requiresImageStaging || (externalInput == nil && (request.input.width != request.outputWidth || request.input.height != request.outputHeight)) {
            input = try .init(device: request.device, width: request.input.width, height: request.input.height,
                              format: request.renderer.imageInputFormat, ledger: ledger)
        } else { input = nil }
        let preparationInput = input?.texture ?? externalInput ?? output
        if let requirements = request.observations, !requirements.features.isEmpty {
            observations = try .init(device: request.device, width: request.input.width, height: request.input.height,
                                     requirements: requirements, ledger: ledger)
        } else { observations = nil }
        arena = Arena(device: request.device, ledger: ledger)
        // Encode without submitting: this runs the exact effect schedule, acquiring its
        // maximum simultaneous workspace and kernel weights without processing pixels.
        for index: UInt32 in [0, 1] {
            try autoreleasepool {
                guard let command = request.renderer.queue.makeCommandBuffer() else { throw LabError.io("Cannot prepare frame command") }
                let frame = try request.frame(index: index)
                try request.renderer.encoder.encodePrepared(preparationInput, output: output, prepared: frame, arena: arena, command: command)
            }
            // Include the next frame's peak while cached noise still owns its textures.
            arena.reset()
        }
        arena.clearNoise(); arena.reset(); arena.allowsAllocation = false
    }
}

/// Exclusive, single-submission use of already allocated effect storage.
/// Acquire a new handle for the next frame; its underlying storage may be reused.
public final class ProcessingWorkspace: @unchecked Sendable {
    let storage: ProcessingWorkspaceStorage
    let scheduler: ProcessingScheduler?
    private let lock = UnfairLock()
    private var claimed = false
    private let recycle: (ProcessingWorkspaceStorage) -> Void
    init(_ storage: ProcessingWorkspaceStorage, scheduler: ProcessingScheduler? = nil, recycle: @escaping (ProcessingWorkspaceStorage) -> Void) {
        self.storage = storage; self.recycle = recycle; self.scheduler = scheduler
    }
    func claim(for request: PreparedProcessingRequest, additionalClaim: () -> Bool = { true }) -> Bool {
        lock.withLock {
            guard !claimed, storage.prepared.matchesResources(request), additionalClaim() else { return false }
            claimed = true; return true
        }
    }
    deinit {
        storage.arena.reset()
        recycle(storage)
    }
}
