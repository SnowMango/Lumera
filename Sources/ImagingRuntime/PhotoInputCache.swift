import Foundation
import ImagingCore
import ImageRendering

/// Select whether this operation leaves its prepared source pixels in the cache.
/// Preview, full output and viewport renders currently all acquire full-source pixels.
public enum PhotoInputRetention: Sendable {
    case retain
    case evictAfterUse
}

/// Owns prepared input textures, including pixels pinned by active operations.
/// Source storage, preparation workspace and decoder allocations are outside this residency limit.
public actor PhotoInputCache {
    public let maxResidentBytes: Int
    public var residentBytes: Int { storage.bytes }

    private let storage: PhotoCacheStorage
    private var retained: [PhotoInputKey: PhotoInputLease] = [:]
    private var live: [PhotoInputKey: WeakEntry] = [:]
    private var pending: [PhotoInputKey: Build] = [:]
    private var generation = UUID()

    private struct WeakEntry {
        weak var value: PhotoInputLease?
    }

    private struct Build {
        let id = UUID()
        let generation: UUID
        let task: Task<PhotoInputLease, Error>
    }

    public init(maxResidentBytes: Int) throws {
        guard maxResidentBytes > 0 else { throw LabError.invalid("Photo cache requires a positive residency limit") }
        self.maxResidentBytes = maxResidentBytes
        storage = PhotoCacheStorage(limit: maxResidentBytes)
    }

    /// Drop cached references. Work already using them keeps its storage through GPU completion.
    /// Pending builds still serve their existing waiters, without repopulating this generation.
    public func evictAll() {
        generation = UUID()
        retained.removeAll()
        live.removeAll()
    }

    func acquire(_ key: PhotoInputKey, retention: PhotoInputRetention,
                 build: @escaping @Sendable () async throws -> PhotoInputResidency) async throws -> PhotoInputLease {
        try Task.checkCancellation()
        if let hit = live[key]?.value {
            retained[key] = retention == .retain ? hit : nil
            return hit
        }
        let flight: Build
        if let current = pending[key] {
            flight = current
        } else {
            live = live.filter { $0.value.value != nil }
            let task = Task { [storage] in
                let residency = try await build()
                let charge = try storage.reserve(residency.input.residentStorageBytes)
                return PhotoInputLease(residency: residency, charge: charge)
            }
            flight = Build(generation: generation, task: task)
            pending[key] = flight
        }

        // A cancellation belongs to the waiter. The shared build runs to completion.
        let entry: PhotoInputLease
        do { entry = try await flight.task.value }
        catch {
            if pending[key]?.id == flight.id { pending[key] = nil }
            throw error
        }
        if pending[key]?.id == flight.id {
            pending[key] = nil
            if flight.generation == generation { live[key] = WeakEntry(value: entry) }
        }
        try Task.checkCancellation()
        if live[key]?.value === entry {
            retained[key] = retention == .retain ? entry : nil
        }
        return entry
    }
}

struct PhotoInputKey: Hashable, Sendable {
    enum Geometry: Hashable, Sendable { case fullSource }
    let revision: UUID
    let recipe: String
    let working: String
    let calibration: String
    let geometry: Geometry
    let precision: ExecutionPrecision
    let device: UInt64

    init(source: PhotoSource, model: PreparedCameraModel) {
        revision = source.revision
        recipe = source.recipeID
        working = source.workingID
        calibration = source.calibrationID
        geometry = .fullSource
        precision = model.execution.precision
        device = model.renderer.device.registryID
    }
}

/// Cache entries own one physical allocation. A second ledger charges that same allocation
/// once while it is in use on that ledger, with no duplicate texture or persistent model binding.
final class PhotoInputLease: @unchecked Sendable {
    let origin: PhotoInputResidency
    private let charge: PhotoCacheStorage.Charge
    private let lock = NSLock()
    private var borrowed: [ObjectIdentifier: Borrow] = [:]
    private struct Borrow {
        weak var residency: PhotoInputResidency?
    }

    fileprivate init(residency: PhotoInputResidency, charge: PhotoCacheStorage.Charge) {
        origin = residency
        self.charge = charge
    }

    func residency(for model: PreparedCameraModel) throws -> PhotoInputResidency {
        lock.lock(); defer { lock.unlock() }
        if origin.budgetID == model.photoBudgetID { return origin }
        if let current = borrowed[model.photoBudgetID]?.residency { return current }
        borrowed = borrowed.filter { $0.value.residency != nil }
        let residency = try model.accountPhotoInput(origin.input)
        borrowed[model.photoBudgetID] = Borrow(residency: residency)
        return residency
    }
}

private final class PhotoCacheStorage: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var used = 0
    var bytes: Int {
        lock.lock(); defer { lock.unlock() }
        return used
    }
    init(limit: Int) { self.limit = limit }

    func reserve(_ bytes: Int) throws -> Charge {
        lock.lock(); defer { lock.unlock() }
        guard bytes <= limit - used else { throw LabError.invalid("Prepared photo exceeds available input cache residency") }
        used += bytes
        return Charge(storage: self, bytes: bytes)
    }

    final class Charge: Sendable {
        private let storage: PhotoCacheStorage
        private let bytes: Int
        init(storage: PhotoCacheStorage, bytes: Int) {
            self.storage = storage
            self.bytes = bytes
        }
        deinit {
            storage.lock.lock()
            storage.used -= bytes
            storage.lock.unlock()
        }
    }
}
