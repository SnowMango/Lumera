import Foundation
import Metal
import ImagingCore
import ImageRendering

public struct BenchmarkDistribution: Codable {
    public let medianMS: Double, p95MS: Double
    init(_ values: [Double]) {
        let sorted = values.sorted()
        func percentile(_ fraction: Double) -> Double {
            sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * fraction)) - 1)]
        }
        medianMS = percentile(0.5); p95MS = percentile(0.95)
    }
}

public struct RendererTiming: Codable {
    public let prepareMS: Double, cpu: BenchmarkDistribution, gpu: BenchmarkDistribution, frame: BenchmarkDistribution
}

public struct BenchmarkRound: Codable {
    public let index: Int, fixedGPU: BenchmarkDistribution, dynamicGPU: BenchmarkDistribution
}

public struct BenchmarkReport: Codable {
    public let device: String, system: String, renderer: String, profileDigest: String
    public let width: Int, height: Int, precision: String, warmupFrames: Int, samplesPerMode: Int, rounds: Int
    public let fixed: RendererTiming, dynamic: RendererTiming, pairedRounds: [BenchmarkRound]
    public let observedPeakAllocatedBytes: Int
    public let sustainedSeconds: Double, sustainedFrames: Int, sustainedGPU: BenchmarkDistribution?
    public let thermalAtStart: Int, thermalAtEnd: Int, allocatedBytes: Int, cachedTextureBytes: Int
    public let scope: String
}

public enum RenderingBenchmark {
    /// Paired frames at the same ISO and seed sequence. Alternating AB/BA removes ordering bias.
    public static func run(profile: Profile, width: Int, height: Int, samples: Int = 120,
                           rounds: Int = 3, sustainedSeconds: Double = 60) throws -> BenchmarkReport {
        let thermal = ProcessInfo.processInfo.thermalState.rawValue
        guard samples > 0, samples <= 10000, (1...10).contains(rounds), (0...600).contains(sustainedSeconds),
              let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw LabError.invalid("无效的测量设置或无可用的 Metal 设备")
        }
        try TextureDimensions.validate(width:width,height:height,device:device)
        let encoder = try TextureEffectEncoder(device:device)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba16Float,width:width,height:height,mipmapped:false)
        descriptor.storageMode = .shared; descriptor.usage = [.shaderRead]
        guard let input = device.makeTexture(descriptor:descriptor) else { throw LabError.io("无法分配测量输入纹理") }
        var row = [UInt16](repeating:0,count:width*4)
        for x in 0..<width {
            let value = Float16(Float(x) / Float(max(1,width-1))).bitPattern
            row[x*4] = value; row[x*4+1] = value; row[x*4+2] = value; row[x*4+3] = Float16(1).bitPattern
        }
        row.withUnsafeBytes { bytes in
            for y in 0..<height { input.replace(region:MTLRegionMake2D(0,y,width,1),mipmapLevel:0,
                withBytes:bytes.baseAddress!,bytesPerRow:width*8) }
        }
        func now() -> Double { ProcessInfo.processInfo.systemUptime }
        var conditions = CaptureConditions(); conditions.iso = 400; conditions.exposureDurationSeconds = 1/60
        let start = now(), definition = try StyleEvaluator.compile(profile)
        let dynamic = try encoder.prepare(definition), dynamicPrepare = (now()-start)*1000
        let fixedStart = now(), resolved = try StyleEvaluator.evaluate(definition,conditions:conditions).resolvedStyle()
        let fixed = try encoder.prepare(resolved), fixedPrepare = (now()-fixedStart)*1000
        var request = RenderRequest(input: .init(width:width,height:height))
        var observedPeakAllocatedBytes = device.currentAllocatedSize
        struct Sample { let cpu: Double, gpu: Double, total: Double }
        func frame(dynamicMode: Bool, index: Int) throws -> Sample {
            try Task.checkCancellation()
            return try autoreleasepool {
                request.frameIndex = UInt32(truncatingIfNeeded:index)
                guard let command = queue.makeCommandBuffer() else { throw LabError.io("无法创建测量 GPU 任务") }
                let begin = now()
                if dynamicMode {
                    let evaluated = try StyleEvaluator.evaluate(definition,conditions:conditions)
                    _ = try encoder.encode(input,style:dynamic,parameters:.init(evaluated),request:request,commandBuffer:command)
                } else { _ = try encoder.encode(input,style:fixed,request:request,commandBuffer:command) }
                let cpu = (now()-begin)*1000
                observedPeakAllocatedBytes = max(observedPeakAllocatedBytes, device.currentAllocatedSize)
                command.commit(); command.waitUntilCompleted()
                if let error = command.error { throw error }
                guard command.status == .completed else { throw LabError.io("测量 GPU 工作未完成") }
                return Sample(cpu:cpu,gpu:(command.gpuEndTime-command.gpuStartTime)*1000,total:(now()-begin)*1000)
            }
        }
        for i in 0..<10 { _ = try frame(dynamicMode:false,index:i); _ = try frame(dynamicMode:true,index:i) }
        var fixedFrames = [Sample](), dynamicFrames = [Sample]()
        var pairedRounds = [BenchmarkRound]()
        for round in 0..<rounds {
            var fixedGPU = [Double](), dynamicGPU = [Double]()
            for index in 0..<samples {
                let dynamicFirst = (round + index) % 2 == 1
                for dynamicMode in [dynamicFirst, !dynamicFirst] {
                    let sample = try frame(dynamicMode: dynamicMode, index: round * samples + index)
                    if dynamicMode { dynamicFrames.append(sample); dynamicGPU.append(sample.gpu) }
                    else { fixedFrames.append(sample); fixedGPU.append(sample.gpu) }
                }
            }
            pairedRounds.append(.init(index: round + 1, fixedGPU: .init(fixedGPU), dynamicGPU: .init(dynamicGPU)))
        }
        var sustained = [Double]()
        let sustainStart = now()
        while now()-sustainStart < sustainedSeconds { sustained.append(try frame(dynamicMode:true,index:sustained.count).gpu) }
        func timing(_ rows: [Sample], prepare: Double) -> RendererTiming {
            RendererTiming(prepareMS:prepare,cpu:.init(rows.map(\.cpu)),gpu:.init(rows.map(\.gpu)),frame:.init(rows.map(\.total)))
        }
        return BenchmarkReport(device:device.name,system:ProcessInfo.processInfo.operatingSystemVersionString,
            renderer:LumeraVersion.rendererRevision,profileDigest:definition.identity,width:width,height:height,precision:"Float16",
            warmupFrames:10,samplesPerMode:samples,rounds:rounds,fixed:timing(fixedFrames,prepare:fixedPrepare),
            dynamic:timing(dynamicFrames,prepare:dynamicPrepare),pairedRounds:pairedRounds,
            observedPeakAllocatedBytes:observedPeakAllocatedBytes,sustainedSeconds:now()-sustainStart,sustainedFrames:sustained.count,
            sustainedGPU:sustained.isEmpty ? nil : .init(sustained),thermalAtStart:thermal,thermalAtEnd:ProcessInfo.processInfo.thermalState.rawValue,
            allocatedBytes:device.currentAllocatedSize,cachedTextureBytes:encoder.cachedTextureBytes,
            scope:"One frame in flight; encode + GPU completion, all optical layers at full scale. Excludes camera, decoding, display and file I/O.")
    }
}
