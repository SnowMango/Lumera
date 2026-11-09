import Foundation
import XCTest
import ImagingCore
@testable import ImageAnalysis

final class InputCalibrationSolverTests: XCTestCase {
    private func encoded(_ x: Double) -> Double { x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055 }
    private func linear(_ x: Double) -> Double { x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
    private let source = SourceDescriptor(id: "camera", path: .processedPhoto)
    private let working = WorkingImageContract(referenceRenditionID: "controlled-reference")
    private var recipe: EffectiveInputRecipe { .init(declared: .init(id: "recipe", backend: "coreImage", version: "1"), backendVersion: "test") }

    func testKnownSourceTransformRecovery() throws {
        // Independent analytical fixture; training and held-out linear colors are disjoint.
        let training = [[0.06,0.12,0.22],[0.4,0.1,0.2],[0.12,0.5,0.08],[0.03,0.09,0.6],[0.3,0.4,0.2]]
        func expected(_ x: [Double]) -> [Double] { [0.91*x[0]+0.06*x[1], 0.03*x[0]+1.02*x[1], 0.04*x[1]+0.88*x[2]] }
        let pairs = training.map { InputCalibrationPair(input: $0.map(encoded), reference: expected($0).map(encoded)) }
        let fit = try InputCalibrationSolver.fit(pairs: pairs, source: source, effectiveRecipe: recipe, reference: working, options: .init())
        for x in [[0.21,0.31,0.41],[0.7,0.04,0.13],[0.02,0.23,0.51]] {
            let matrix = fit.correction.matrix.values
            let actual = (0..<3).map { row in encoded((0..<3).reduce(0) { $0 + matrix[row*3+$1] * x[$1] }) }
            for (a, b) in zip(actual, expected(x).map(encoded)) { XCTAssertLessThanOrEqual(abs(a-b), 0.005) }
        }
        XCTAssertEqual(fit.recipeDigest, try recipe.digest())
        XCTAssertTrue(fit.qualifications.isEmpty)
        XCTAssertEqual(fit.tone, .identity)
        XCTAssertTrue(fit.resources.isEmpty)
    }
    func testIdentityReferenceIsExplicit() throws {
        let identity = try InputCalibrationSolver.identity(source: source, effectiveRecipe: recipe, reference: working)
        XCTAssertTrue(identity.id.hasPrefix("unqualified-reference:"))
        XCTAssertEqual(identity.working.referenceRenditionID, "controlled-reference")
        XCTAssertEqual(identity.correction.matrix, ColorMatrix3x3())
        XCTAssertTrue(identity.qualifications.isEmpty)
        XCTAssertThrowsError(try InputCalibrationSolver.fit(pairs: [], source: source, effectiveRecipe: recipe, reference: working, options: .init()))
    }
    func testRankDeficientAndMalformedPairsReject() throws {
        let gray = [0.2,0.4,0.6].map { InputCalibrationPair(input: [$0,$0,$0], reference: [$0,$0,$0]) }
        XCTAssertThrowsError(try InputCalibrationSolver.fit(pairs: gray, source: source, effectiveRecipe: recipe, reference: working, options: .init()))
        let malformed = [InputCalibrationPair(input: [.nan,0,0], reference: [0,0,0])]
        XCTAssertThrowsError(try InputCalibrationSolver.fit(pairs: malformed, source: source, effectiveRecipe: recipe, reference: working, options: .init()))
    }
    func testFixedMatrixRemainsIdentityAndSampleBudgetIsEnforced() throws {
        let pairs = [InputCalibrationPair(input: [0.2,0.3,0.4], reference: [0.3,0.4,0.5])]
        let fit = try InputCalibrationSolver.fit(pairs: pairs, source: source, effectiveRecipe: recipe, reference: working,
                                                options: .init(fixedParameters: ["color.matrix"]))
        XCTAssertEqual(fit.correction.matrix, ColorMatrix3x3())
        XCTAssertThrowsError(try InputCalibrationSolver.fit(pairs: pairs + pairs, source: source, effectiveRecipe: recipe, reference: working, options: .init(maxSamples: 1)))
    }
}
