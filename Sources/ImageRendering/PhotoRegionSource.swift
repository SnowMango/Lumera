import Foundation
import CoreImage
import Metal
import ImagingCore

/// Provider-owned storage is charged in addition to SDK workspace. System decoder memory is opaque.
public struct PhotoSourceMemory: Sendable {
    public let knownResidentBytes: Int
    public let hasOpaqueDecoderMemory: Bool
    public init(knownResidentBytes: Int, hasOpaqueDecoderMemory: Bool) {
        self.knownResidentBytes = knownResidentBytes; self.hasOpaqueDecoderMemory = hasOpaqueDecoderMemory
    }
}

/// Immutable, oriented pixels. Implementations must reject unsupported requests, never materialize
/// the full image as a hidden fallback. The returned input leases its region until GPU work finishes.
/// `prepare` must honor the supplied workspace budget (including temporary allocations), perform
/// range preflight before narrowing unknown pixels, and return the requested precision/device.
/// Dimensions, metadata and pixels must remain immutable for the lifetime of a revision. The
/// coordinator serializes requests within an export; shared providers must support concurrent exports.
public protocol PhotoRegionSource: Sendable {
    var revision: UUID { get }
    var width: Int { get }
    var height: Int { get }
    var memory: PhotoSourceMemory { get }
    func prepare(region: CGRect, execution: ExecutionProfile) async throws -> NormalizedInput
}

/// A lazy Core Image graph. CI/RAW decoder allocations are explicitly outside SDK-owned accounting.
public final class ResolvedPhotoSource: PhotoRegionSource, @unchecked Sendable {
    public let revision = UUID()
    public let bounds: CGRect
    public var width: Int { Int(bounds.width) }
    public var height: Int { Int(bounds.height) }
    public let memory: PhotoSourceMemory
    private let renderer: LumeraRenderer
    private let image: CIImage
    private let properties: [String: Any]
    private let descriptor: SourceDescriptor
    private let recipe: EffectiveInputRecipe
    private let working: WorkingImageContract
    private let conditions: CaptureConditions
    private let development: SourceImage.InputDevelopment
    init(renderer: LumeraRenderer, image: CIImage, bounds: CGRect, properties: [String: Any], descriptor: SourceDescriptor,
         recipe: EffectiveInputRecipe, working: WorkingImageContract, conditions: CaptureConditions, development: SourceImage.InputDevelopment, knownResidentBytes: Int) {
        self.memory = PhotoSourceMemory(knownResidentBytes: knownResidentBytes, hasOpaqueDecoderMemory: true)
        self.renderer = renderer; self.image = image; self.bounds = bounds; self.properties = properties
        self.descriptor = descriptor; self.recipe = recipe; self.working = working; self.conditions = conditions; self.development = development
    }
    public func prepare(region: CGRect, execution: ExecutionProfile) async throws -> NormalizedInput {
        try await prepare(region: region, execution: execution, trustedNormalizedRGBBounds: nil)
    }

    func prepare(region: CGRect, execution: ExecutionProfile, trustedNormalizedRGBBounds: NumericBounds?) async throws -> NormalizedInput {
        try Task.checkCancellation(); try execution.validate()
        guard !region.isEmpty, region == region.integral, bounds.contains(region),
              execution.dynamicRange == working.dynamicRange,
              renderer.imageInputFormat == (execution.precision == .float16 ? .rgba16Float : .rgba32Float) else {
            throw LabError.invalid("Invalid region or source execution")
        }
        let range: RenderDynamicRange = execution.dynamicRange == .edr ? .edr : .sdr
        let width = Int(region.width), height = Int(region.height)
        try TextureDimensions.validate(width: width, height: height, device: renderer.device)
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: renderer.imageInputFormat, width: width, height: height, mipmapped: false)
        textureDescriptor.storageMode = .private; textureDescriptor.usage = [.shaderRead, .shaderWrite]
        let workspace = TileWorkingSet(limit: execution.budget.maxResidentBytes)
        let textureBytes = renderer.device.heapTextureSizeAndAlign(descriptor: textureDescriptor).size
        try workspace.reserve(textureBytes)
        // The unknown Half path must inspect Float32 output before writing narrower storage.
        // Float32 already stores at preflight precision; the actual reduction is sufficient.
        if execution.precision == .float16, trustedNormalizedRGBBounds == nil {
            _ = try await renderer.measureInputRange(image, bounds: region, colorSpace: LumeraRenderer.colorSpace(for: range),
                budget: min(64 * 1024 * 1024, execution.budget.maxResidentBytes), requireHalf: true)
        }
        try Task.checkCancellation()
        guard let texture = renderer.device.makeTexture(descriptor: textureDescriptor), let command = renderer.queue.makeCommandBuffer() else { throw LabError.io("Cannot allocate normalized input") }
        try workspace.reserve(max(0, texture.allocatedSize - textureBytes))
        renderer.context.render(image, to: texture, commandBuffer: command, bounds: region, colorSpace: LumeraRenderer.colorSpace(for: range))
        // Core Image 的内部精度可能随输出格式改变，因此从实际写入的纹理读取数值范围。
        let readback = try renderer.rangeReducer.encode(texture, commandBuffer: command, workingSet: workspace)
        try await renderer.complete(command)
        let bounds = try readback.resolve()
        if let declared = trustedNormalizedRGBBounds {
            let stored: (Double) -> Double = { value in
                execution.precision == .float16 ? Double(Float16(Float(value))) : Double(Float(value))
            }
            guard bounds.lower >= stored(declared.lower), bounds.upper <= stored(declared.upper) else {
                throw LabError.invalid("Stored input is outside its trusted normalized RGB range")
            }
        }
        return try NormalizedInput(texture: texture, properties: properties, descriptor: descriptor, recipe: recipe,
            working: working, execution: execution, bounds: bounds, conditions: conditions, inputDevelopment: development)
    }
}

extension LumeraRenderer {
    /// Exact fixed-256 sampling: each grid block includes every pixel touched by its samples.
    /// A sample is accumulated by one GPU thread in the original row-major Float32 order.
    public func observe(_ source: any PhotoRegionSource, normalizer: InputNormalizer,
                        calibration: InputCalibration?, resources: ModelResourceSet, execution: ExecutionProfile,
                        stamp: FrameStamp, requirements: ObservationRequirements) async throws -> FrameObservations {
        let isolation = try encoder.beginBoundedPhotoWork(); defer { isolation.finish() }
        try execution.validate(); try requirements.validate(); try stamp.validate()
        guard requirements.features.count <= 64, requirements.features.allSatisfy({ $0.samplingLongEdge == 256 }) else {
            throw LabError.unsupported("Regional statistics require the fixed-256 feature contract")
        }
        _ = try ImageDimensions.pixelCount(width: source.width, height: source.height)
        guard source.memory.knownResidentBytes >= 0 else { throw LabError.invalid("Negative source memory") }
        let available = execution.budget.maxResidentBytes - source.memory.knownResidentBytes
        guard available > 0, max(source.width, source.height) <= 1 << 24 else { throw LabError.invalid("Source exceeds regional limits") }
        if requirements.features.isEmpty {
            var local = execution; local.budget.maxResidentBytes = available
            let normalized = try await source.prepare(region: CGRect(x: 0, y: 0, width: 1, height: 1), execution: local)
            let input = try await normalizer.normalize(normalized, calibration: calibration, resources: resources, bounded: true)
            return try await observe(input, stamp: stamp, requirements: requirements, maxResidentBytes: available)
        }
        let ratio = min(1, 256 / Double(max(source.width, source.height)))
        let sw = max(1, Int(floor(Double(source.width) * ratio))), sh = max(1, Int(floor(Double(source.height) * ratio)))
        let sampleBytes = device.heapBufferSizeAndAlign(length: sw * sh * 16, options: .storageModePrivate).size
        guard available > sampleBytes + 1024 * 1024 else { throw LabError.invalid("No regional observation workspace") }
        guard let samples = device.makeBuffer(length: sw * sh * 16, options: .storageModePrivate) else { throw LabError.io("Cannot allocate samples") }
        let pipeline = frameFeatures.regionalArea
        var local = execution; local.budget.maxResidentBytes = available - sampleBytes - 1024 * 1024
        // Blocks partition the sample grid, not source pixels. Fractional boundaries intentionally overlap.
        var block = 32
        func footprint(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> CGRect {
            let sx = Float(source.width) / Float(sw), sy = Float(source.height) / Float(sh)
            let x0 = floor(Float(x) * sx), y0 = floor(Float(y) * sy)
            let x1 = min(Float(source.width), ceil(Float(x + w) * sx)), y1 = min(Float(source.height), ceil(Float(y + h) * sy))
            return CGRect(x: Double(x0), y: Double(y0), width: Double(x1 - x0), height: Double(y1 - y0))
        }
        while block > 1 {
            let w = ceil(Float(block) * Float(source.width) / Float(sw)) + 2
            let h = ceil(Float(block) * Float(source.height) / Float(sh)) + 2
            if Double(w * h) * 16 * 12 + 65536 < Double(local.budget.maxResidentBytes) { break }
            block /= 2
        }
        var facts: PreparedInput?
        var identity: String?
        for y in stride(from: 0, to: sh, by: block) {
            for x in stride(from: 0, to: sw, by: block) {
                try Task.checkCancellation()
                facts = nil
                let bw = min(block, sw - x), bh = min(block, sh - y), rect = footprint(x, y, bw, bh)
                guard Double(rect.width * rect.height) * 16 * 12 + 65536 < Double(local.budget.maxResidentBytes) else {
                    throw LabError.unsupported("Budget cannot hold one complete sample footprint")
                }
                let normalized = try await source.prepare(region: rect, execution: local)
                let input = try await normalizer.normalize(normalized, calibration: calibration, resources: resources, bounded: true)
                let current = input.sourceID + ":" + input.calibrationID
                guard identity == nil || identity == current else { throw LabError.invalid("Regional source identity changed") }
                identity = current
                guard input.width == Int(rect.width), input.height == Int(rect.height) else { throw LabError.invalid("Provider returned wrong region geometry") }
                guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else { throw LabError.io("Cannot encode samples") }
                var size = SIMD2<UInt32>(UInt32(sw), UInt32(sh)), full = SIMD2<UInt32>(UInt32(source.width), UInt32(source.height))
                var origin = SIMD2<UInt32>(UInt32(rect.minX), UInt32(rect.minY)), sampleOrigin = SIMD2<UInt32>(UInt32(x), UInt32(y))
                encoder.setComputePipelineState(pipeline); encoder.setTexture(input.texture, index: 0); encoder.setBuffer(samples, offset: 0, index: 0)
                encoder.setBytes(&size, length: 8, index: 1); encoder.setBytes(&full, length: 8, index: 2)
                encoder.setBytes(&origin, length: 8, index: 3); encoder.setBytes(&sampleOrigin, length: 8, index: 4)
                encoder.dispatchThreads(.init(width: bw, height: bh, depth: 1), threadsPerThreadgroup: .init(width: 8, height: 8, depth: 1))
                encoder.endEncoding(); try await complete(command)
                facts = input
            }
        }
        guard let input = facts, let command = queue.makeCommandBuffer() else { throw LabError.io("No regional input facts") }
        let ticket = try frameFeatures.encode(input, stamp: stamp, requirements: requirements, commandBuffer: command,
            budgetLimit: available, regionalSamples: samples, fullSize: .init(source.width, source.height))
        if ticket.readbackBytes > 0 { try await complete(command) }
        return try ticket.resolve()
    }
}
