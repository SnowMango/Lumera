import Foundation
import Metal
import ImagingCore

/// 通过生产渲染管线将选定的输入校正应用到 NormalizedInput，再生成 PreparedInput。
public final class InputNormalizer: @unchecked Sendable {
    private let renderer: LumeraRenderer
    // 锁保护预热绑定和资源缓存。每帧使用取出的快照，GPU 编码和异步等待在锁外进行。
    private let lock = NSLock()
    private struct Cached {
        let calibration: InputCalibration
        let resources: ModelResourceSet
        let identity: String
        let correction: PreparedDeviceCorrection?
        let tone: PreparedCameraStyle
        let resourceBytes: Int
    }
    private var cache: Cached?
    private struct Binding {
        let calibration: InputCalibration?
        let resources: ModelResourceSet
        // 归一化器可比模型存活更久，绑定随自身持有资源租约。
        let residency: ModelResourceLease?
    }
    private var binding: Binding?
    func prewarm(calibration: InputCalibration?, resources: ModelResourceSet, residency: ModelResourceLease?) throws {
        if let calibration { _ = try preparation(calibration, resources: resources) }
        lock.lock(); defer { lock.unlock() }
        binding = Binding(calibration: calibration, resources: resources, residency: residency)
    }
    func checkPreparedBinding(calibration: InputCalibration?, resources: ModelResourceSet) throws {
        _ = try boundResources(calibration: calibration, resources: resources)
    }
    private func boundResources(calibration: InputCalibration?, resources: ModelResourceSet) throws -> ModelResourceSet {
        lock.lock(); defer { lock.unlock() }
        guard let binding else { return resources }
        guard calibration == binding.calibration,
              binding.resources.luts.allSatisfy({ resources.luts[$0.key] == $0.value }) else {
            throw LabError.invalid("Prepared normalizer calibration/resources cannot change")
        }
        return binding.resources
    }
    public init(renderer: LumeraRenderer) { self.renderer = renderer }
    /// 校验来源、实际解码配方和参考契约后应用校正，并测量实际输出范围。
    /// 未选择校正时复用源存储，结果保留参考契约且没有实测资格。
    public func normalize(_ source: NormalizedInput, calibration: InputCalibration?, resources: ModelResourceSet) async throws -> PreparedInput {
        try Task.checkCancellation()
        let selectedResources = try boundResources(calibration: calibration, resources: resources)
        guard source.texture.device.registryID == renderer.device.registryID,
              source.texture.pixelFormat == renderer.imageInputFormat else { throw LabError.invalid("Input belongs to another device or precision") }
        guard let calibration else {
            // 未经实测校正的输入使用单独的参考身份。
            try Self.validateBounds(source.valueBounds, working: source.working)
            let identity = try InputCalibration.unqualifiedReferenceIdentity(working: source.working)
            return PreparedInput(texture: source.texture, source: source, calibrationID: identity, working: source.working,
                                 bounds: source.valueBounds, qualifications: [])
        }
        try calibration.validate()
        guard calibration.source == source.descriptor, calibration.working == source.working,
              calibration.recipeDigest == (try source.effectiveRecipe.digest()) else {
            throw LabError.invalid("Input source, effective recipe or reference does not match calibration")
        }
        let bytes = source.width * source.height * source.execution.precision.bytesPerPixel
        // Validate declared allocation before parsing or uploading a resource.
        let resourceBytes = calibration.resources.reduce(0) { $0 + $1.dimension * $1.dimension * $1.dimension * 16 }
        guard bytes <= (source.execution.budget.maxResidentBytes - min(source.execution.budget.maxResidentBytes, resourceBytes)) / 8 else {
            throw LabError.invalid("Input calibration exceeds execution memory budget")
        }
        let prepared = try preparation(calibration, resources: selectedResources)
        var request = RenderRequest(input: .init(width: source.width, height: source.height))
        request.dynamicRange = source.execution.dynamicRange == .edr ? .edr : .sdr
        request.inputValueBounds = source.valueBounds
        guard let command = renderer.queue.makeCommandBuffer() else { throw LabError.io("Cannot create input correction command") }
        let output = try renderer.encoder.encode(source.texture, style: prepared.tone, correction: prepared.correction,
                                                 request: request, commandBuffer: command)
        let owned: MTLTexture
        if output === source.texture { owned = source.texture }
        else { owned = try renderer.copyOwned(output, commandBuffer: command) }
        let range = try renderer.rangeReducer.encode(owned, commandBuffer: command)
        try await renderer.complete(command)
        let actual = try range.resolve()
        try Self.validateBounds(actual, working: calibration.working)
        return PreparedInput(texture: owned, source: source, calibrationID: prepared.identity, working: calibration.working,
                             bounds: actual, qualifications: calibration.qualifications.filter { qualification in
                                 qualification.conditionRanges.allSatisfy { range in
                                     source.captureConditions[range.axis].map(range.bounds.contains) ?? false
                                 }
                             })
    }
    private static func validateBounds(_ actual: NumericBounds, working: WorkingImageContract) throws {
        if case .finite(let declared) = working.valueBounds {
            guard actual.lower >= declared.lower, actual.upper <= declared.upper else {
                throw LabError.invalid("Prepared input exceeds declared working range")
            }
        }
    }
    /// 供运行时准备和离线打包共用，检查内存中校正资源的摘要、域、样本范围与边界策略。
    public static func validateResources(_ calibration: InputCalibration, resources: ModelResourceSet) throws {
        _ = try validatedResources(calibration, resources: resources)
    }
    private static func validatedResources(_ calibration: InputCalibration, resources: ModelResourceSet) throws -> (LUTAsset?, Int) {
        try calibration.validate()
        guard calibration.resources.count <= 1, calibration.resources.allSatisfy({ $0.role == .correctionLUT }) else {
            throw LabError.unsupported("Input calibration supports one correction LUT and its explicit tone curve")
        }
        var lut: LUTAsset?, resourceBytes = 0
        if let descriptor = calibration.resources.first {
            guard var asset = resources.luts[descriptor.id], asset.sha256 == descriptor.sha256,
                  descriptor.inputDomain == .encodedSRGB, descriptor.outputDomain == .encodedSRGB,
                  descriptor.inputBounds == NumericBounds(lower: 0, upper: 1) else { throw LabError.invalid("Correction LUT resource/contract mismatch") }
            try asset.preflightDimension(descriptor.dimension)
            let cube = try asset.decodedCube()
            guard cube.size == descriptor.dimension, cube.rgba.enumerated().allSatisfy({ $0.offset % 4 == 3 || descriptor.outputBounds.contains(Double($0.element)) }) else { throw LabError.invalid("Correction LUT samples do not match descriptor") }
            switch descriptor.outOfRange {
            case .clamp: asset.boundaryPolicy = .clamp
            case .linearExtrapolation: asset.boundaryPolicy = .extrapolate
            case .reject: throw LabError.unsupported("Reject-boundary correction LUT requires a proven intermediate domain")
            }
            lut = asset; resourceBytes = cube.rgba.count * MemoryLayout<Float>.stride
        }
        return (lut, resourceBytes)
    }
    private func preparation(_ calibration: InputCalibration, resources: ModelResourceSet) throws -> Cached {
        lock.lock(); defer { lock.unlock() }
        if let cached = cache, cached.calibration == calibration, cached.resources == resources { return cached }
        let (lut, resourceBytes) = try Self.validatedResources(calibration, resources: resources)
        var parameters = StyleParameters()
        parameters.tone.enabled = calibration.tone != .identity
        parameters.tone.curve = calibration.tone
        let prepared = Cached(calibration: calibration, resources: resources, identity: try calibration.digest(),
                              correction: try renderer.prepareCorrection(calibration.correction, lut: lut),
                              tone: try renderer.prepare(ResolvedStyle(parameters: parameters)), resourceBytes: resourceBytes)
        cache = prepared
        return prepared
    }
}

extension LumeraRenderer {
    func copyOwned(_ source: MTLTexture, commandBuffer: MTLCommandBuffer) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: source.pixelFormat, width: source.width, height: source.height, mipmapped: false)
        descriptor.storageMode = .private; descriptor.usage = .shaderRead
        guard let result = device.makeTexture(descriptor: descriptor), let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw LabError.io("Cannot allocate owned input storage")
        }
        blit.copy(from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(x: 0, y: 0, z: 0),
                  sourceSize: .init(width: source.width, height: source.height, depth: 1), to: result,
                  destinationSlice: 0, destinationLevel: 0, destinationOrigin: .init(x: 0, y: 0, z: 0))
        blit.endEncoding(); return result
    }
}
