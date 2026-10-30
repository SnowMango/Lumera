import XCTest
import ImagingCore
@testable import ImageAnalysis

final class GenerationCheckTests:XCTestCase {
    func testUnimplementedAlgorithmsNeverGrantEligibility() async throws {
        let report=try await GenerationCheck.run(algorithms:AlgorithmID.allCases)
        XCTAssertEqual(Set(report.results.map(\.algorithm)),Set(AlgorithmID.allCases))
        for id in AlgorithmID.allCases where !GenerationLimits.implemented.contains(id) {
            XCTAssertTrue(report.results.filter{$0.algorithm==id}.allSatisfy{$0.status == .insufficient})
            XCTAssertThrowsError(try GenerationEligibility(report:report,required:[id]))
        }
        XCTAssertNoThrow(try GenerationEligibility(report:report,required:[.independentLUT]))
        XCTAssertNoThrow(try GenerationEligibility(report:report,required:[.toneColor]))
        for id in [AlgorithmID.targetDetection,.captureQuality] {
            XCTAssertThrowsError(try GenerationEligibility(report:report,required:[id]),"Digital checks do not replace real-camera evidence")
        }
        for row in report.results where GenerationLimits.implemented.contains(row.algorithm) && !row.caseID.hasPrefix("real") {
            XCTAssertEqual(row.status,.passed,"\(row.algorithm.rawValue)/\(row.caseID): \(row.detail)")
        }
        let data=try JSON.encode(report),restored=try JSONDecoder().decode(AlgorithmCheckReport.self,from:data)
        XCTAssertEqual(restored,report)
        if let output=ProcessInfo.processInfo.environment["LUMERA_GENERATION_REPORT"] {try data.write(to:URL(fileURLWithPath:output))}
        XCTAssertFalse(report.materialDigest.isEmpty);XCTAssertFalse(report.gpu.isEmpty)
    }
    func testRejectsMissingDuplicateStaleOrNonPassingEvidence() async throws {
        let valid=try await GenerationCheck.run(algorithms:[.independentLUT])
        for status in [AlgorithmCheckStatus.failed,.insufficient,.skipped] {
            var report=valid;report.results[0].status=status
            XCTAssertThrowsError(try GenerationEligibility(report:report,required:[.independentLUT]))
        }
        var report=valid;report.engineVersion="old"
        XCTAssertThrowsError(try GenerationEligibility(report:report,required:[.independentLUT]))
        report=valid;report.results.removeLast()
        XCTAssertThrowsError(try GenerationEligibility(report:report,required:[.independentLUT]))
        report=valid;report.results.append(report.results[0])
        XCTAssertThrowsError(try GenerationEligibility(report:report,required:[.independentLUT]))
        report=valid;report.materialDigest="stale"
        XCTAssertThrowsError(try GenerationEligibility(report:report,required:[.independentLUT]))
        report=valid;report.results[0].measured=1
        XCTAssertThrowsError(try GenerationEligibility(report:report,required:[.independentLUT]))
        report=valid;report.results[0].limit.absoluteTolerance=99
        XCTAssertThrowsError(try GenerationEligibility(report:report,required:[.independentLUT]))
    }
    func testCancellationDoesNotProduceEligibility() async throws {
        let task=Task {try await GenerationCheck.run(algorithms:AlgorithmID.allCases)}
        task.cancel()
        do {_=try await task.value;XCTFail("Cancelled run must not yield a completed report")}catch is CancellationError {}
    }
}
