import Foundation
import Metal
import ImagingCore

struct RenderTile {
    let core: CGRect, area: CGRect, sourceArea: CGRect
}

/// All rectangles are in the single, oriented image coordinate system. Halo is cumulative
/// for serial stages; parallel branches contribute their largest support.
struct TilePlanner {
    let sourceWidth: Int, sourceHeight: Int, fullWidth: Int, fullHeight: Int
    let budget: Int, halo: Int
    private let fullTextureSlots: Int
    private let reducedTextureSlots: [(EffectResolution, Int)]
    private let sourceSlots: Int, grainSubdivision: Int

    init(width: Int, height: Int, style: StyleParameters, options: RenderOptions, budget: Int, preparedGrain: PreparedGrain?) throws {
        _ = try ImageDimensions.pixelCount(width: width, height: height)
        guard max(width,height) <= 1 << 24, budget > 0 else { throw LabError.invalid("分块尺寸或工作内存预算无效") }
        try options.makeRequest(input: .init(width: width, height: height)).validate()
        sourceWidth = width; sourceHeight = height; self.budget = budget
        let limit = min(options.maximumLongEdge ?? max(width,height), max(width,height))
        let ratio = Double(limit) / Double(max(width,height))
        fullWidth = max(1, Int(Double(width) * ratio)); fullHeight = max(1, Int(Double(height) * ratio))
        let scale = EffectScale.factor(width: fullWidth, height: fullHeight)
        grainSubdivision = preparedGrain?.subdivision(scale:scale) ?? 1
        func optical(_ sigma: Double, _ divisor: EffectResolution, support: Double = 3) -> Int {
            // Every reduced sample covers up to divisor full pixels; include bilinear reconstruction.
            let d = divisor.rawValue
            return Int(ceil(support * sigma * scale)) + (d == 1 ? 1 : 3 * d)
        }
        var extent = 0
        if style.detail.isActive {
            extent += Int(ceil(3 * max(style.detail.fineSigma, style.detail.midSigma) * scale))
            if style.detail.sharpenAmount > 0 { extent += Int(ceil(3 * style.detail.sharpenSigma * scale)) }
        }
        if style.softening.isActive { extent += optical(style.softening.sigma, options.softeningScale) }
        if options.previewGlow && style.glow.isActive { extent += optical(style.glow.farSigma, options.glowScale) }
        if options.previewGlow && style.halation.isActive {
            extent += optical(PreparedHalation(radius: style.halation.radius).sigmas[2], options.halationScale, support: 4)
        }
        if style.noise.isActive { extent += Int(ceil(3 * max(style.noise.chromaSigma, style.noise.lumaSigma) * scale)) }
        halo = extent
        let spatial = options.previewGlow
        // Per distinct grid, arena storage is reusable between stages; parallel blur
        // branches hold their inputs and combined result until the merge pass.
        var slots = 3
        if style.detail.isActive || style.noise.isActive { slots = max(slots, 5) }
        var layers = [EffectResolution: Int]()
        for (active, resolution, live) in [(style.softening.isActive, options.softeningScale, 4),
            (spatial && style.glow.isActive, options.glowScale, 6),
            (spatial && style.halation.isActive, options.halationScale, 8)] where active {
            if resolution == .full { slots = max(slots, live) }
            else { layers[resolution] = max(layers[resolution] ?? 0, live) }
        }
        fullTextureSlots = slots + 2 // pooled leftovers and readback
        reducedTextureSlots = layers.map { ($0.key, $0.value) }
        sourceSlots = (width == fullWidth && height == fullHeight) ? 1 : 5

    }

    func tile(_ core: CGRect) -> RenderTile {
        let frame = CGRect(x: 0, y: 0, width: fullWidth, height: fullHeight)
        let area = core.insetBy(dx: -CGFloat(halo), dy: -CGFloat(halo)).intersection(frame)
        let sx = Double(sourceWidth) / Double(fullWidth), sy = Double(sourceHeight) / Double(fullHeight)
        var source = area
        if sourceWidth != fullWidth || sourceHeight != fullHeight {
            source = CGRect(x: area.minX * sx, y: area.minY * sy, width: area.width * sx, height: area.height * sy)
                .insetBy(dx: -1, dy: -1).integral.intersection(CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight))
        }
        return RenderTile(core: core, area: area, sourceArea: source)
    }

    /// Conservative peak for all stage grids including input, correction, optical branches,
    /// texture row alignment, core readback and kernel buffers; no reuse of unrelated idle arenas.
    func fits(_ tile: RenderTile) -> Bool {
        func alignedBytes(_ w: CGFloat, _ h: CGFloat) -> Double { ceil(w * 16 / 256) * 256 * h }
        let sourceBytes = alignedBytes(tile.sourceArea.width, tile.sourceArea.height)
        let outputBytes = alignedBytes(tile.area.width, tile.area.height)
        let factor = CGFloat(grainSubdivision)
        let grainBytes = grainSubdivision > 1 ? alignedBytes(tile.area.width*factor,tile.area.height*factor) : 0
        var bytes = sourceBytes * Double(sourceSlots) + outputBytes * Double(fullTextureSlots) + grainBytes
        for (resolution, live) in reducedTextureSlots {
            let d = CGFloat(resolution.rawValue)
            bytes += alignedBytes(ceil(tile.area.width/d)+1,ceil(tile.area.height/d)+1)*Double(live)
        }
        return bytes + 65536 <= Double(budget)
    }

    func forEachTile(region: CGRect, _ body: (RenderTile) async throws -> Void) async throws {
        var side = min(1024, max(Int(region.width), Int(region.height)))
        while true {
            // Bound the largest halo anywhere in the region before committing the first tile.
            let w = min(CGFloat(fullWidth), CGFloat(min(side,Int(region.width)) + 2 * halo))
            let h = min(CGFloat(fullHeight), CGFloat(min(side,Int(region.height)) + 2 * halo))
            let worst = RenderTile(core: .zero, area: CGRect(x:0,y:0,width:w,height:h), sourceArea: CGRect(x:0,y:0,
                width:min(CGFloat(sourceWidth),ceil(w * CGFloat(sourceWidth) / CGFloat(fullWidth)) + 4),
                height:min(CGFloat(sourceHeight),ceil(h * CGFloat(sourceHeight) / CGFloat(fullHeight)) + 4)))
            if fits(worst) { break }
            if side == 1 { break }
            side = max(1, side / 2)
        }
        func render(_ core: CGRect) async throws {
            try Task.checkCancellation()
            do { try await body(tile(core)) }
            catch is TileAllocationLimit {
                let horizontal = core.width >= core.height
                let length = horizontal ? core.width : core.height
                guard length >= 2 else { throw LabError.unsupported("最小分块含邻域仍超过 GPU 工作预算或单张纹理限制") }
                let parts = core.divided(atDistance: floor(length/2), from: horizontal ? .minXEdge : .minYEdge)
                try await render(parts.slice)
                try await render(parts.remainder)
            }
        }
        for y in stride(from: Int(region.minY), to: Int(region.maxY), by: side) {
            for x in stride(from: Int(region.minX), to: Int(region.maxX), by: side) {
                try Task.checkCancellation()
                let core = CGRect(x:x,y:y,width: min(side,Int(region.maxX)-x),height:min(side,Int(region.maxY)-y))
                try await render(core)
            }
        }
    }
}

/// Per-command accounting. Metal objects referenced by an encoded command remain live
/// until completion, including buffers evicted from a kernel cache before completion.
struct TileAllocationLimit: Error {}

final class TileWorkingSet {
    let limit: Int
    private(set) var bytes = 0
    init(limit: Int) { self.limit = limit }

    func reserve(_ size: Int) throws {
        guard size >= 0, size <= limit - bytes else { throw TileAllocationLimit() }
        bytes += size
    }

    func reserve(texture: MTLTextureDescriptor, on device: MTLDevice) throws {
        try reserve(device.heapTextureSizeAndAlign(descriptor: texture).size)
    }

    func reserve(bufferLength: Int, on device: MTLDevice) throws {
        try reserve(device.heapBufferSizeAndAlign(length:bufferLength,options:.storageModeShared).size)
    }
}
