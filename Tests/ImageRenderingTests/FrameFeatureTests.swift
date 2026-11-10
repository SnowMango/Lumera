import XCTest
import CoreImage
import Metal
import ImageIO
import ImagingCore
@testable import ImageRendering

final class FrameFeatureTests: XCTestCase {
    func input(_ renderer: LumeraRenderer, width: Int, height: Int, values: [Float], outputSize: Int = 1, orientation: CGImagePropertyOrientation? = nil) async throws -> PreparedInput {
        let image = CIImage(bitmapData: values.withUnsafeBytes { Data($0) }, bytesPerRow: width * 16, size: .init(width: width, height: height), format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        var descriptor = SourceDescriptor(id: "fixture", path: .processedPhoto); descriptor.recipeID = "ci"
        var execution = ExecutionProfile(width: outputSize, height: outputSize, budget: .init(maxInFlightFrames: 1, maxResidentBytes: 64 * 1024 * 1024))
        execution.precision = renderer.imageInputFormat == .rgba32Float ? .float32 : .float16
        let normalized = try await InputAdapter(renderer: renderer, working: .init(referenceRenditionID: "fixture")).prepare(.image(image, metadata: ["{Exif}": ["ISOSpeedRatings": [400]]], orientation: orientation), descriptor: descriptor, recipe: .init(id: "ci", backend: "coreImage", version: "1", decodedRendition: .baseImage), execution: execution)
        return try await InputNormalizer(renderer: renderer).normalize(normalized, calibration: nil, resources: .init())
    }
    var stamp: FrameStamp { .init(streamID: "fixture", generation: 4, index: 7, presentationTime: 0.7, duration: 0.1) }
    var requirements: ObservationRequirements {
        var r = ObservationRequirements()
        r.features = [.init(id: "p01", statistic: .luminanceQuantile(0.01)), .init(id: "p50", statistic: .luminanceQuantile(0.5)), .init(id: "p99", statistic: .luminanceQuantile(0.99)), .init(id: "dark", statistic: .fractionBelow(0.01)), .init(id: "bright", statistic: .fractionAbove(0.99)), .init(id: "red", statistic: .meanRed)]
        return r
    }
    func testHistogramKnownDistribution() async throws {
        let renderer = try LumeraRenderer(precision: .float32)
        let prepared = try await input(renderer, width: 2, height: 2, values: [0,0,0,1, 0,0,0,1, 1,1,1,1, 1,1,1,1])
        let command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
        let ticket = try FrameFeatureExtractor(device: renderer.device).encode(prepared, stamp: stamp, requirements: requirements, commandBuffer: command)
        XCTAssertThrowsError(try ticket.resolve())
        try await renderer.complete(command)
        let observations = try ticket.resolve(), values = observations.features.compactMap(\.value)
        XCTAssertEqual(values[0], 0.5 / 256, accuracy: 1e-8)
        XCTAssertEqual(values[1], 0.5 / 256, accuracy: 1e-8)
        XCTAssertEqual(values[2], 255.5 / 256, accuracy: 1e-8)
        XCTAssertEqual(values[3], 0.5, accuracy: 1e-8); XCTAssertEqual(values[4], 0.5, accuracy: 1e-8)
        XCTAssertEqual(values[5], 0.5, accuracy: 1e-6)
        XCTAssertLessThan(ticket.readbackBytes, 2048)
    }
    func testConstantProgramSkipsStatistics() async throws {
        let renderer = try LumeraRenderer()
        let prepared = try await input(renderer, width: 1, height: 1, values: [0.5,0.5,0.5,1])
        let command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
        let ticket = try FrameFeatureExtractor(device: renderer.device).encode(prepared, stamp: stamp, requirements: .init(), commandBuffer: command)
        XCTAssertEqual(ticket.readbackBytes, 0)
        XCTAssertTrue(try ticket.resolve().features.isEmpty)
        XCTAssertEqual(command.status, .notEnqueued)
    }
    func testObservationCarriesSameFrameMetadata() async throws {
        let renderer = try LumeraRenderer()
        let prepared = try await input(renderer, width: 1, height: 1, values: [0.5,0.5,0.5,1])
        let command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
        let ticket = try FrameFeatureExtractor(device: renderer.device).encode(prepared, stamp: stamp, requirements: requirements, commandBuffer: command)
        try await renderer.complete(command)
        let observation = try ticket.resolve()
        XCTAssertEqual(observation.stamp, stamp); XCTAssertEqual(observation.captureConditions, prepared.captureConditions)
        XCTAssertEqual(observation.sourceID, prepared.sourceID); XCTAssertEqual(observation.calibrationID, prepared.calibrationID)
        XCTAssertEqual(observation.featureDigest, try requirements.featureDigest())
        XCTAssertEqual(ticket.sampleWidth, 1); XCTAssertEqual(ticket.sampleHeight, 1)
        XCTAssertEqual(observation.features.last!.value!, pow((0.5 + 0.055) / 1.055, 2.4), accuracy: 1e-5)
    }
    func testViewportDoesNotChangeFullImageFeatures() async throws {
        let renderer = try LumeraRenderer(precision: .float32)
        var pixels: [Float] = []
        for y in 0..<3 { for x in 0..<513 { let v: Float = (x + y) % 2 == 0 ? 1 : 0; pixels += [v,v,v,1] } }
        var results: [Double] = []
        for size in [32, 1024] {
            let prepared = try await input(renderer, width: 513, height: 3, values: pixels, outputSize: size)
            let command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
            let ticket = try FrameFeatureExtractor(device: renderer.device).encode(prepared, stamp: stamp, requirements: requirements, commandBuffer: command)
            XCTAssertEqual(ticket.sampleWidth, 256); XCTAssertEqual(ticket.sampleHeight, 1)
            try await renderer.complete(command)
            results.append(try ticket.resolve().features.last!.value!)
        }
        XCTAssertEqual(results[0], results[1], accuracy: 1e-8)
        XCTAssertEqual(results[0], Double(770) / Double(1539), accuracy: 1e-5)
    }
    func testOrientationPreservesWholeImageStatistics() async throws {
        let renderer = try LumeraRenderer(precision: .float32)
        let pixels: [Float] = [0,0,0,1, 1,1,1,1, 0,0,0,1, 1,1,1,1, 0,0,0,1, 1,1,1,1]
        var observations: [[FeatureValue]] = []
        for orientation: CGImagePropertyOrientation in [.up, .right] {
            let prepared = try await input(renderer, width: 2, height: 3, values: pixels, orientation: orientation)
            let command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
            let ticket = try FrameFeatureExtractor(device: renderer.device).encode(prepared, stamp: stamp, requirements: requirements, commandBuffer: command)
            try await renderer.complete(command)
            observations.append(try ticket.resolve().features)
        }
        XCTAssertEqual(observations[0], observations[1])
    }
    func testClippingAndRejectedInvalidPixels() async throws {
        let renderer = try LumeraRenderer(precision: .float32)
        let base = try await input(renderer, width: 2, height: 1, values: [0,0,0,1, 1,1,1,1])
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: 2, height: 1, mipmapped: false)
        td.storageMode = .shared; td.usage = .shaderRead
        for invalid in [false, true] {
            let texture = try XCTUnwrap(renderer.device.makeTexture(descriptor: td))
            let values: [Float] = [invalid ? .nan : -0.5,-0.5,-0.5,1, 2,2,2,1]
            values.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, 2, 1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 32) }
            let prepared = PreparedInput(texture: texture, source: base.source, calibrationID: base.calibrationID, working: base.working, bounds: .init(lower: -0.5, upper: 2), qualifications: [])
            let command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
            let ticket = try FrameFeatureExtractor(device: renderer.device).encode(prepared, stamp: stamp, requirements: requirements, commandBuffer: command)
            XCTAssertThrowsError(try ticket.clippingFractions())
            try await renderer.complete(command)
            if invalid { XCTAssertThrowsError(try ticket.resolve()) }
            else {
                let clip = try ticket.clippingFractions()
                XCTAssertEqual(clip.belowZero, 0.5); XCTAssertEqual(clip.aboveOne, 0.5)
                XCTAssertEqual(try ticket.resolve().features[1].value!, 0.5 / 256, accuracy: 1e-8)
            }
        }
    }

    func testThresholdsPreserveDeclaredDoubleBoundary() async throws {
        let renderer = try LumeraRenderer(precision: .float32)
        let prepared = try await input(renderer, width: 1, height: 1, values: [1,1,1,1])
        var r = ObservationRequirements()
        r.features = [.init(id: "below", statistic: .fractionBelow(1 - 1e-8)), .init(id: "above", statistic: .fractionAbove(1 + 1e-8))]
        let command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
        let ticket = try FrameFeatureExtractor(device: renderer.device).encode(prepared, stamp: stamp, requirements: r, commandBuffer: command)
        try await renderer.complete(command)
        XCTAssertEqual(try ticket.resolve().features.compactMap(\.value), [0, 0])
    }

    func testStatisticsBudgetIncludesRetainedInputStorage() async throws {
        let renderer = try LumeraRenderer(precision: .float32)
        let prepared = try await input(renderer, width: 256, height: 256, values: Array(repeating: [Float(0.5), 0.5, 0.5, 1], count: 256 * 256).flatMap { $0 })
        var execution = prepared.execution
        execution.budget.maxResidentBytes = 2 * 256 * 256 * 16
        let source = try NormalizedInput(texture: prepared.source.texture, properties: prepared.source.properties, descriptor: prepared.source.descriptor, recipe: prepared.source.effectiveRecipe, working: prepared.source.working, execution: execution, bounds: prepared.source.valueBounds, conditions: prepared.captureConditions, inputDevelopment: prepared.source.inputDevelopment)
        let bounded = PreparedInput(texture: prepared.texture, source: source, calibrationID: prepared.calibrationID, working: prepared.working, bounds: prepared.valueBounds, qualifications: [])
        let command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
        XCTAssertThrowsError(try FrameFeatureExtractor(device: renderer.device).encode(bounded, stamp: stamp, requirements: requirements, commandBuffer: command))
    }

    func testFullGridParallelSummaryMatchesIndependentCPU() async throws {
        let renderer = try LumeraRenderer(precision: .float32)
        var pixels: [Float] = [], histogram = [Int](repeating: 0, count: 256)
        var red = 0.0, green = 0.0, blue = 0.0, dark = 0, bright = 0
        func decode(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        for y in 0..<256 { for x in 0..<256 {
            let r = Float((x * 17 + y * 3) % 251) / 250
            let g = Float((x * 7 + y * 19) % 241) / 240
            let b = Float((x * 23 + y * 11) % 239) / 238
            pixels += [r, g, b, 1]
            let lr = decode(Double(r)), lg = decode(Double(g)), lb = decode(Double(b))
            red += lr; green += lg; blue += lb
            let luminance = 0.2126 * lr + 0.7152 * lg + 0.0722 * lb
            histogram[min(255, Int(luminance * 256))] += 1
            if luminance <= 0.137 { dark += 1 }; if luminance >= 0.713 { bright += 1 }
        } }
        let prepared = try await input(renderer, width: 256, height: 256, values: pixels)
        var r = ObservationRequirements()
        r.features = [.init(id: "r", statistic: .meanRed), .init(id: "g", statistic: .meanGreen), .init(id: "b", statistic: .meanBlue), .init(id: "dark", statistic: .fractionBelow(0.137)), .init(id: "bright", statistic: .fractionAbove(0.713)), .init(id: "median", statistic: .luminanceQuantile(0.5))]
        let command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
        let ticket = try FrameFeatureExtractor(device: renderer.device).encode(prepared, stamp: stamp, requirements: r, commandBuffer: command)
        XCTAssertEqual(ticket.reductionPartitionCount, 256)
        try await renderer.complete(command)
        let actual = try ticket.resolve().features.compactMap(\.value)
        for (a, expected) in zip(actual.prefix(3), [red, green, blue]) { XCTAssertEqual(a, expected / 65536, accuracy: 2e-6) }
        XCTAssertEqual(actual[3], Double(dark) / 65536, accuracy: 1e-8)
        XCTAssertEqual(actual[4], Double(bright) / 65536, accuracy: 1e-8)
        var accumulated = 0, median = 0
        for i in 0..<256 { accumulated += histogram[i]; if accumulated >= 32768 { median = i; break } }
        XCTAssertEqual(actual[5], (Double(median) + 0.5) / 256, accuracy: 1e-8)
    }

}
