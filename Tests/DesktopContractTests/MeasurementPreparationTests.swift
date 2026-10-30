@testable import ImageAnalysis
import XCTest
import ImagingCore
import ImageRendering
final class MeasurementPreparationTests: XCTestCase {
    private let regions = [Region(), Region(x:0.17,y:0.13,width:0.66,height:0.71),
                           Region(x:0.4,y:0.4,width:0.2,height:0.2)]

    // The frozen implementation catches a changed channel, reduction order, ROI,
    // scale, or diagnostic contract without sharing the optimized code's helpers.
    func testAllKindsMatchOriginalAcrossFixturesCropsAndScales() throws {
        for fixture in Fixture.allCases {
            let image = try Fixtures.make(fixture,width:128,height:112)
            for kind in MeasurementKind.allCases {
                for region in regions {
                    for scale in [0.05, 0.5, 1, 1 + 5e-9, 2, 20] {
                        compare(image,region:region,kind:kind,scale:scale,
                                context:"\(fixture) / \(kind) / \(region) / \(scale)")
                    }
                }
            }
        }
        let colorNoise = try noisyImage()
        for kind in MeasurementKind.allCases {
            for region in regions { compare(colorNoise,region:region,kind:kind) }
        }
    }

    func testInvalidInputsMatchOriginal() throws {
        let image = try ImageFrame.solid(width:64,height:64,value:0)
        for kind in MeasurementKind.allCases {
            for scale in [Double.nan, .infinity, -.infinity, 0, 0.049, 20.001] {
                compare(image,kind:kind,scale:scale)
            }
            for region in [Region(x:-0.1), Region(x:.nan), Region(width:0),
                           Region(width:1.1), Region(width:0.2),
                           Region(x:0.8,width:0.2000005)] {
                compare(image,region:region,kind:kind)
            }
            compare(image,kind:kind)
        }
        let small = try ImageFrame.solid(width:15,height:32,value:0.5)
        for kind in MeasurementKind.allCases { compare(small,kind:kind) }
    }

    func testMeanOnlyMatchesNoiseMeasurementExactly() throws {
        for image in [try noisyImage(), try Fixtures.make(.ramp,width:128,height:112),
                      try Fixtures.make(.patches,width:128,height:112)] {
            for region in regions {
                let expected = try LegacyMeasurementEngine.measure(image,region:region,kind:.noise)
                let actual = try MeasurementEngine.meanLuminance(image,region:region)
                XCTAssertEqual(actual.mean,expected.metrics["mean"])
                XCTAssertEqual(actual.width,expected.pixelWidth)
                XCTAssertEqual(actual.height,expected.pixelHeight)
            }
        }
    }

    func testMeanOnlyRejectsInvalidOrTooSmallROI() throws {
        let image = try ImageFrame.solid(width:64,height:64,value:0.5)
        for region in [Region(x:-0.1), Region(width:.nan), Region(width:0.2)] {
            let expected = Result { try LegacyMeasurementEngine.measure(image,region:region,kind:.noise) }
            XCTAssertThrowsError(try MeasurementEngine.meanLuminance(image,region:region)) { error in
                if case let .failure(original) = expected {
                    XCTAssertEqual(String(describing:error),String(describing:original))
                } else { XCTFail("Original measurement should reject this ROI") }
            }
        }
    }

    func testCancelledMeasurementAndMeanOnlyThrow() async throws {
        let image = try noisyImage()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            for kind in MeasurementKind.allCases {
                XCTAssertThrowsError(try MeasurementEngine.measure(image,kind:kind)) {
                    XCTAssertTrue($0 is CancellationError)
                }
            }
            XCTAssertThrowsError(try MeasurementEngine.meanLuminance(image)) {
                XCTAssertTrue($0 is CancellationError)
            }
        }
        try await task.value
    }

    func testOptInReleaseMeasurementBenchmark() throws {
        guard ProcessInfo.processInfo.environment["CCDLAB_BENCHMARK_MEASUREMENTS"] == "1" else {
            throw XCTSkip("Set CCDLAB_BENCHMARK_MEASUREMENTS=1 and use swift test -c release --filter MeasurementPreparationTests/testOptInReleaseMeasurementBenchmark")
        }
        #if DEBUG
        throw XCTSkip("Measurement benchmark requires a release build")
        #else
        // Fixture construction and equality checks are outside the timed interval.
        // Alternating order reduces cache/order bias; report medians, not a threshold.
        for (kind,fixture) in [(MeasurementKind.edge,Fixture.edge),(.noise,.texture),
                               (.texture,.texture),(.vignette,.flat),(.glow,.point)] {
            let image = try (kind == .noise || kind == .texture)
                ? noisyImage(width:2048,height:1536)
                : Fixtures.make(fixture,width:2048,height:1536)
            let expected = try LegacyMeasurementEngine.measure(image,kind:kind)
            assertEqual(try MeasurementEngine.measure(image,kind:kind),expected)
            var oldTimes=[Double](),newTimes=[Double]()
            for iteration in 0..<3 {
                if iteration % 2 == 0 {
                    oldTimes.append(try timed { try LegacyMeasurementEngine.measure(image,kind:kind) })
                    newTimes.append(try timed { try MeasurementEngine.measure(image,kind:kind) })
                } else {
                    newTimes.append(try timed { try MeasurementEngine.measure(image,kind:kind) })
                    oldTimes.append(try timed { try LegacyMeasurementEngine.measure(image,kind:kind) })
                }
            }
            let old=oldTimes.sorted()[1],new=newTimes.sorted()[1]
            print("MEASUREMENT_BENCHMARK kind=\(kind.rawValue) pixels=3145728 oldMedianSeconds=\(old) newMedianSeconds=\(new) ratio=\(old/new)")
        }
        #endif
    }

    private func timed(_ work:() throws -> ImageAnalysis.Measurement) rethrows -> Double {
        let start=ProcessInfo.processInfo.systemUptime
        let result=try work()
        let elapsed=ProcessInfo.processInfo.systemUptime-start
        XCTAssertTrue(result.metrics["mean"]!.isFinite)
        return elapsed
    }

    private func noisyImage(width:Int=131,height:Int=119) throws -> ImageFrame {
        var image=try ImageFrame.solid(width:width,height:height,value:0.5)
        var seed:UInt64=0xfeed1234
        for i in image.pixels.indices where i % 4 != 3 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            image.pixels[i]=Float(seed >> 40)/Float(1 << 24)
        }
        return image
    }

    private func compare(_ image:ImageFrame,region:Region=Region(),kind:MeasurementKind,
                         scale:Double=1,context:String="",file:StaticString=#filePath,line:UInt=#line) {
        let expected=Result { try LegacyMeasurementEngine.measure(image,region:region,kind:kind,scale:scale) }
        let actual=Result { try MeasurementEngine.measure(image,region:region,kind:kind,scale:scale) }
        switch (actual,expected) {
        case let (.success(a),.success(e)): assertEqual(a,e,context:context,file:file,line:line)
        case let (.failure(a),.failure(e)):
            XCTAssertEqual(String(describing:a),String(describing:e),context,file:file,line:line)
        default: XCTFail("Original and optimized measurement disagree on success/failure: \(context)",file:file,line:line)
        }
    }

    private func assertEqual(_ actual:ImageAnalysis.Measurement,_ expected:ImageAnalysis.Measurement,context:String="",
                             file:StaticString=#filePath,line:UInt=#line) {
        XCTAssertEqual(actual.kind,expected.kind,context,file:file,line:line)
        if actual.kind == .edge {
            XCTAssertEqual(Set(actual.metrics.keys),Set(expected.metrics.keys),context,file:file,line:line)
            for (key,value) in expected.metrics {XCTAssertEqual(actual.metrics[key] ?? .infinity,value,accuracy:1e-10,context,file:file,line:line)}
        } else {XCTAssertEqual(actual.metrics,expected.metrics,context,file:file,line:line)}
        XCTAssertEqual(Set(actual.curves.keys),Set(expected.curves.keys),context,file:file,line:line)
        for (name,expectedCurve) in expected.curves {
            guard let actualCurve=actual.curves[name] else {continue}
            XCTAssertEqual(actualCurve.count,expectedCurve.count,"\(context) / \(name)",file:file,line:line)
            for (index,pair) in zip(actualCurve,expectedCurve).enumerated() {
                guard pair.0 == pair.1 || (actual.kind == .edge && abs(pair.0-pair.1)<1e-10) else {
                    XCTFail("\(context) / \(name)[\(index)]: \(pair.0) != \(pair.1)",file:file,line:line)
                    break
                }
            }
        }
        XCTAssertEqual(actual.warnings,expected.warnings,context,file:file,line:line)
        XCTAssertEqual(actual.roi,expected.roi,context,file:file,line:line)
        XCTAssertEqual(actual.pixelWidth,expected.pixelWidth,context,file:file,line:line)
        XCTAssertEqual(actual.pixelHeight,expected.pixelHeight,context,file:file,line:line)
        XCTAssertEqual(actual.scale,expected.scale,context,file:file,line:line)
        XCTAssertEqual(actual.method,expected.method,context,file:file,line:line)
    }
}
