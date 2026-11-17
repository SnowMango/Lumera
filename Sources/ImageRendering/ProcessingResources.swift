import Foundation
import Metal
import ImagingCore

public enum ProcessingPreparationResult {
    case ready
    case wouldBlock(FrameAdmissionIssue)
    case failure(Error)
}
public enum FrameAcquisition {
    case ready(FrameResources)
    case unavailable(FrameAdmissionIssue)
}

/// Explicit frame preparation may allocate; acquiring prepared frames never grows their pool.
/// Measured input conversion requests individual textures on demand, within the same budget.
/// Share this instance between streams to share their hard resource budget.
public final class ProcessingResources: @unchecked Sendable {
    private let lock = UnfairLock()
    let ledger: ProcessingResourceLedger
    private let device: MTLDevice
    private var generation: UInt64 = 0
    private var closed = false
    private var preparing = false
    private var leasedWorkspaces = 0
    private var reportedIdle = 0
    private func syncIdle() {
        let actual = idleBytes
        ledger.changeIdle(by: actual - reportedIdle); reportedIdle = actual
    }
    deinit { ledger.changeIdle(by: -reportedIdle) }
    private var workspaces: [ProcessingWorkspaceStorage] = []
    private var outputs: [ProcessingTextureStorage] = []
    private var inputTextures: [ProcessingTextureStorage] = []
    private var rangeBuffers: [ProcessingBufferStorage] = []
    private lazy var scheduler = ProcessingScheduler { [ledger] in ledger.policy }
    private var prepared: PreparedProcessingRequest?
    public init(device: MTLDevice, limits: ProcessingResourceLimits = .init(), policy: ProcessingPolicy = .init()) {
        self.device = device; ledger = ProcessingResourceLedger(limits: limits, policy: policy)
        ledger.registerOwner(self)
    }
    private init(device: MTLDevice, ledger: ProcessingResourceLedger) {
        self.device = device; self.ledger = ledger
        ledger.registerOwner(self)
    }
    /// A separate stream/descriptor cache drawing from the same host budget.
    public func makeStreamResources() -> ProcessingResources { .init(device: device, ledger: ledger) }
    public var policyWarnings: [String] { ledger.policyWarnings }
    @discardableResult
    public func updatePolicy(_ policy: ProcessingPolicy) -> ProcessingPolicyUpdate {
        let update = ledger.update(policy)
        ledger.trimOwners()
        return .init(requested: update.requested, effective: update.effective,
                     isShrinking: ledger.residentBytes > update.effective.maxResidentBytes, warnings: update.warnings)
    }
    func trimSharedIdle() { lock.withLock { trimIdle() } }
    func checkExternalPreparation(_ request: PreparedProcessingRequest) throws {
        try lock.withLock {
            guard !closed else { throw FrameAdmissionIssue.closed }
            guard request.device.registryID == device.registryID else { throw FrameAdmissionIssue.incompatibleResources }
        }
    }
    func checkRangeDevice(_ registryID: UInt64) throws {
        guard device.registryID == registryID else { throw FrameAdmissionIssue.incompatibleResources }
    }
    func clearIdleRangeBuffers() { lock.withLock { rangeBuffers.removeAll(); syncIdle() } }
    public func prepare(_ request: PreparedProcessingRequest) -> ProcessingPreparationResult {
        let start: (UInt64, Bool)? = lock.withLock {
            guard !closed, !preparing, request.device.registryID == device.registryID else { return nil }
            if let prepared, prepared.matchesResources(request), !workspaces.isEmpty, !outputs.isEmpty { return (generation, false) }
            generation &+= 1; prepared = nil; workspaces.removeAll(); outputs.removeAll(); syncIdle(); preparing = true
            return (generation, true)
        }
        guard let (epoch, needsPreparation) = start else { return .wouldBlock(.busy) }
        if !needsPreparation { return .ready }
        do {
            let policy = ledger.policy
            var newWorkspaces: [ProcessingWorkspaceStorage] = [], newOutputs: [ProcessingTextureStorage] = []
            func allocate() throws -> (ProcessingTextureStorage, ProcessingWorkspaceStorage) {
                let output = try ProcessingTextureStorage(device: device, width: request.outputWidth,
                    height: request.outputHeight, format: request.outputPixelFormat, ledger: ledger)
                let workspace = try ProcessingWorkspaceStorage(request: request, output: output.texture, ledger: ledger)
                return (output, workspace)
            }
            func allocateReclaimingBuffers() throws -> (ProcessingTextureStorage, ProcessingWorkspaceStorage) {
                do { return try allocate() }
                catch FrameAdmissionIssue.budgetExhausted {
                    // No owner lock is held while reclaiming shared-ledger idle storage.
                    ledger.clearIdleRangeBuffers()
                    return try allocate()
                }
            }
            for _ in 0..<(policy.maxInFlightFrames + policy.maxPendingFrames) {
                do {
                    let (output, workspace) = try allocateReclaimingBuffers()
                    newOutputs.append(output); newWorkspaces.append(workspace)
                } catch FrameAdmissionIssue.budgetExhausted where !newWorkspaces.isEmpty { break }
            }
            return lock.withLock {
                preparing = false
                guard !closed, generation == epoch else { return .wouldBlock(.closed) }
                prepared = request; workspaces = newWorkspaces; outputs = newOutputs
                syncIdle(); ledger.retainPreparedBytes(ledger.idleBytes)
                return .ready
            }
        } catch {
            lock.withLock { preparing = false }
            if let issue = error as? FrameAdmissionIssue { return .wouldBlock(issue) }
            return .failure(error)
        }
    }
    public func acquireFrame(for request: PreparedProcessingRequest) -> FrameAcquisition {
        let acquired: Result<(ProcessingWorkspaceStorage, ProcessingTextureStorage, UInt64), FrameAdmissionIssue> = lock.withLock {
            guard !closed else { return .failure(.closed) }
            guard let prepared, prepared.matchesResources(request) else { return .failure(.notPrepared) }
            guard ledger.residentBytes <= ledger.policy.maxResidentBytes,
                  leasedWorkspaces < ledger.policy.maxInFlightFrames + ledger.policy.maxPendingFrames,
                  !workspaces.isEmpty, !outputs.isEmpty else { return .failure(.busy) }
            leasedWorkspaces += 1
            let acquired = (workspaces.removeLast(), outputs.removeLast(), generation)
            syncIdle(); return .success(acquired)
        }
        switch acquired {
        case .failure(let issue): return .unavailable(issue)
        case .success(let (storage, output, epoch)):
            let workspace = ProcessingWorkspace(storage, scheduler: scheduler) { [weak self] in self?.recycle($0, epoch: epoch) }
            do {
                return .ready(try FrameResources(workspace: workspace, output: output) { [weak self] in self?.recycle($0, epoch: epoch) })
            } catch { return .unavailable(.incompatibleResources) }
        }
    }
    /// One texture for the stage that needs it, never an output/workspace pair.
    /// The view's lifetime (including retained GPU references) owns the lease.
    func acquireInputTexture(width: Int, height: Int, format: MTLPixelFormat) throws -> MTLTexture {
        try TextureDimensions.validate(width: width, height: height, device: device)
        let (storage, epoch) = try lock.withLock { () throws -> (ProcessingTextureStorage, UInt64) in
            guard !closed else { throw FrameAdmissionIssue.closed }
            let storage: ProcessingTextureStorage
            if let index = inputTextures.firstIndex(where: {
                $0.texture.width == width && $0.texture.height == height && $0.texture.pixelFormat == format
            }) {
                storage = inputTextures.remove(at: index)
            } else {
                func allocate() throws -> ProcessingTextureStorage {
                    try ProcessingTextureStorage(device: device, width: width, height: height,
                        format: format, ledger: ledger, adaptingPolicy: false, usage: [.shaderRead, .shaderWrite])
                }
                func reclaimAndAllocate() throws -> ProcessingTextureStorage {
                    while true {
                        do { return try allocate() }
                        catch FrameAdmissionIssue.budgetExhausted where !inputTextures.isEmpty || !rangeBuffers.isEmpty {
                            if !inputTextures.isEmpty { inputTextures.removeLast() } else { rangeBuffers.removeLast() }; syncIdle()
                        }
                    }
                }
                storage = try reclaimAndAllocate()
            }
            syncIdle()
            return (storage, generation)
        }
        return try leasedProcessingTexture(storage) { [weak self] value in
            self?.lock.withLock {
                guard let self, !self.closed, self.generation == epoch else { return }
                self.inputTextures.append(value); self.syncIdle(); self.trimIdle()
            }
        }
    }
    /// One exact-size reduction buffer, charged while leased or retained idle.
    func acquireRangeBuffer(length: Int, options: MTLResourceOptions) throws -> ProcessingBufferLease {
        let (storage, epoch) = try lock.withLock { () throws -> (ProcessingBufferStorage, UInt64) in
            guard !closed else { throw FrameAdmissionIssue.closed }
            let storage: ProcessingBufferStorage
            if let index = rangeBuffers.firstIndex(where: { $0.buffer.length == length && $0.options == options }) {
                storage = rangeBuffers.remove(at: index)
            } else {
                while true {
                    do {
                        storage = try ProcessingBufferStorage(device: device, length: length, options: options, ledger: ledger)
                        break
                    } catch FrameAdmissionIssue.budgetExhausted {
                        if !rangeBuffers.isEmpty { rangeBuffers.removeLast() }
                        else if !inputTextures.isEmpty { inputTextures.removeLast() }
                        else { throw FrameAdmissionIssue.budgetExhausted }
                        syncIdle()
                    }
                }
            }
            syncIdle()
            return (storage, generation)
        }
        return ProcessingBufferLease(storage: storage) { [weak self] value in
            self?.lock.withLock {
                guard let self, !self.closed, self.generation == epoch else { return }
                self.rangeBuffers.append(value); self.syncIdle(); self.trimIdle()
            }
        }
    }
    public func clearAllIdleResources() { ledger.clearOwners() }
    public func clearIdleResources() {
        lock.withLock { generation &+= 1; workspaces.removeAll(); outputs.removeAll(); inputTextures.removeAll(); rangeBuffers.removeAll(); prepared = nil; syncIdle() }
    }
    public func close() {
        lock.withLock { closed = true; generation &+= 1; workspaces.removeAll(); outputs.removeAll(); inputTextures.removeAll(); rangeBuffers.removeAll(); prepared = nil; syncIdle() }
    }
    public func snapshot() -> ProcessingResourceSnapshot {
        lock.withLock { .init(residentBytes: ledger.residentBytes, idleBytes: ledger.idleBytes,
            activeFrames: leasedWorkspaces, allocationCount: ledger.allocationCount, effectivePolicy: ledger.policy) }
    }
    private var idleBytes: Int {
        workspaces.reduce(0) { $0 + $1.bytes } + outputs.reduce(0) { $0 + $1.charge.bytes }
            + inputTextures.reduce(0) { $0 + $1.charge.bytes } + rangeBuffers.reduce(0) { $0 + $1.charge.bytes }
    }
    private func trimIdle() {
        let policy = ledger.policy
        while ledger.idleBytes > policy.maxIdleBytes || ledger.residentBytes > policy.maxResidentBytes {
            if !workspaces.isEmpty { workspaces.removeLast() }
            else if !outputs.isEmpty { outputs.removeLast() }
            else if !inputTextures.isEmpty { inputTextures.removeLast() }
            else if !rangeBuffers.isEmpty { rangeBuffers.removeLast() }
            else { break }
            syncIdle()
        }
    }
    private func recycle(_ value: ProcessingWorkspaceStorage, epoch: UInt64) {
        lock.withLock {
            leasedWorkspaces -= 1
            guard !closed, generation == epoch else { return }
            workspaces.append(value); syncIdle(); trimIdle()
        }
    }
    private func recycle(_ value: ProcessingTextureStorage, epoch: UInt64) {
        lock.withLock {
            guard !closed, generation == epoch else { return }
            outputs.append(value); syncIdle(); trimIdle()
        }
    }
}
