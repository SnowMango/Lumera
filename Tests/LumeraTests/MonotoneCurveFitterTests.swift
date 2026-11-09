import XCTest
import ImagingCore
@testable import ImageAnalysis

final class MonotoneCurveFitterTests: XCTestCase {
    func testCurveGeneratedWithoutManualKnots() throws {
        let samples = (0...124).map { i in
            let x = Double(i) / 124
            return MonotoneCurveFitter.Sample(x: x, y: 0.12 + 0.76 * x * x)
        }
        let result = try MonotoneCurveFitter.fit(samples: samples, regularization: 0, maxIterations: 1000, tolerance: 1e-10)
        XCTAssertEqual(result.curve.knots.count, 32)
        XCTAssertEqual(result.curve.knots.first!.y, 0.12, accuracy: 0.001)
        XCTAssertEqual(result.curve.knots.last!.y, 0.88, accuracy: 0.001)
        XCTAssertEqual(result.curve.value(at: 0.5), 0.31, accuracy: 0.001)
        XCTAssertTrue(result.diagnostics.converged)
        for (i, point) in result.curve.knots.enumerated() { XCTAssertEqual(point.x, Double(i) / 31) }
        try result.curve.validate(kind: .tone)
    }
    func testWeightedProjectionPoolsConflictingMeasurements() throws {
        var samples = (0..<32).map { MonotoneCurveFitter.Sample(x: Double($0) / 31, y: Double($0) / 31) }
        samples[10] = .init(x: 10.0 / 31, y: 0.6, weight: 3)
        samples[11] = .init(x: 11.0 / 31, y: 0.2, weight: 1)
        for i in 12..<31 { samples[i] = .init(x: Double(i) / 31, y: 0.7 + Double(i - 12) / 100) }
        let result = try MonotoneCurveFitter.fit(samples: samples, regularization: 0)
        XCTAssertEqual(result.curve.knots[10].y, 0.5, accuracy: 1e-8)
        XCTAssertEqual(result.curve.knots[11].y, 0.5, accuracy: 1e-8)
        try result.curve.validate(kind: .tone)
    }
    func testRegularizationReducesCurvatureAndReportsIterationLimit() throws {
        let samples = (0..<32).map { i in MonotoneCurveFitter.Sample(x: Double(i) / 31, y: i < 16 ? 0.1 : 0.9) }
        let raw = try MonotoneCurveFitter.fit(samples: samples, regularization: 0)
        let smooth = try MonotoneCurveFitter.fit(samples: samples, regularization: 10, maxIterations: 2000, tolerance: 1e-9)
        func curvature(_ curve: ResponseCurve) -> Double {
            let y = curve.knots.map(\.y)
            return (1..<31).reduce(0) { $0 + pow(y[$1 - 1] - 2 * y[$1] + y[$1 + 1], 2) }
        }
        XCTAssertLessThan(curvature(smooth.curve), curvature(raw.curve))
        let limited = try MonotoneCurveFitter.fit(samples: samples, regularization: 10, maxIterations: 1, tolerance: 1e-14)
        XCTAssertEqual(limited.diagnostics.iterations, 1)
        XCTAssertFalse(limited.diagnostics.converged)
    }
    func testInvalidAndUnidentifiableEvidenceRejects() throws {
        let endpoints: [MonotoneCurveFitter.Sample] = [.init(x: 0, y: 0.2), .init(x: 1, y: 0.8)]
        for samples in [[], [.init(x: 0.5, y: 0.5)], [.init(x: 0, y: .nan), .init(x: 1, y: 1)], [.init(x: 0, y: 0, weight: 0), .init(x: 1, y: 1)]] as [[MonotoneCurveFitter.Sample]] {
            XCTAssertThrowsError(try MonotoneCurveFitter.fit(samples: samples))
        }
        XCTAssertThrowsError(try MonotoneCurveFitter.fit(samples: endpoints, regularization: 0))
        XCTAssertThrowsError(try MonotoneCurveFitter.fit(samples: endpoints, regularization: -1))
        XCTAssertThrowsError(try MonotoneCurveFitter.fit(samples: endpoints, maxIterations: 0))
        XCTAssertThrowsError(try MonotoneCurveFitter.fit(samples: endpoints, tolerance: .nan))
        let result = try MonotoneCurveFitter.fit(samples: endpoints)
        XCTAssertEqual(result.curve.value(at: 0.5), 0.5, accuracy: 1e-8)
    }
    func testDeterministicUnderSampleOrderAndWeightScale() throws {
        let samples = (0...64).map { i in MonotoneCurveFitter.Sample(x: Double(i) / 64, y: 0.15 + 0.7 * Double(i) / 64, weight: Double(i + 1)) }
        let a = try MonotoneCurveFitter.fit(samples: samples)
        let b = try MonotoneCurveFitter.fit(samples: samples.reversed().map { .init(x: $0.x, y: $0.y, weight: $0.weight * 100) })
        for (x, y) in zip(a.curve.knots, b.curve.knots) { XCTAssertEqual(x.y, y.y, accuracy: 1e-10) }
    }
    func testInteriorEvidenceMarksExtendedEndpointsUnmeasured() throws {
        let samples = (0...20).map { i in
            let x = 0.2 + Double(i) * 0.03
            return MonotoneCurveFitter.Sample(x: x, y: 0.1 + 0.8 * x)
        }
        let result = try MonotoneCurveFitter.fit(samples: samples, maxIterations: 1000)
        XCTAssertEqual(result.diagnostics.measuredRange.lowerBound, 0.2)
        XCTAssertEqual(result.diagnostics.measuredRange.upperBound, 0.8, accuracy: 1e-12)
        XCTAssertEqual(result.diagnostics.unmeasuredIntervals.count, 2)
        XCTAssertEqual(result.curve.value(at: 0.5), 0.5, accuracy: 1e-8)
        try result.curve.validate(kind: .tone)
    }

}
