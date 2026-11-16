import XCTest
@testable import ImageRendering

final class ProcessingBudgetTests: XCTestCase {
    func testInvalidPolicyNormalizesWithoutThrowing() {
        let ledger = ProcessingResourceLedger(limits: .init(), policy: .init())
        let request = ProcessingPolicy(maxResidentBytes: -1, maxIdleBytes: Int.max,
                                       maxInFlightFrames: Int.max, maxPendingFrames: -4)
        let result = ledger.update(request)
        XCTAssertEqual(result.effective.maxResidentBytes, 256 * 1024 * 1024)
        XCTAssertEqual(result.effective.maxIdleBytes, result.effective.maxResidentBytes)
        XCTAssertEqual(result.effective.maxInFlightFrames, 8)
        XCTAssertEqual(result.effective.maxPendingFrames, 0)
        XCTAssertFalse(result.warnings.isEmpty)
        XCTAssertTrue(ledger.update(request).warnings.isEmpty)
    }
    func testTwoStreamsShareOneLimit() throws {
        let ledger = ProcessingResourceLedger(limits: .init(maxResidentBytes: 100), policy: .init())
        let first = try ledger.reserve(60)
        XCTAssertThrowsError(try ledger.reserve(41))
        let second = try ledger.reserve(40)
        XCTAssertEqual(ledger.residentBytes, 100)
        withExtendedLifetime((first, second)) {}
    }
    func testOldGenerationCountsWhileShrinking() throws {
        let ledger = ProcessingResourceLedger(limits: .init(maxResidentBytes: 100), policy: .init())
        var old: ProcessingResourceCharge? = try ledger.reserve(80)
        XCTAssertEqual(old?.bytes, 80)
        XCTAssertTrue(ledger.update(.init(maxResidentBytes: 40)).isShrinking)
        XCTAssertThrowsError(try ledger.reserve(1))
        old = nil
        let next = try ledger.reserve(40)
        XCTAssertEqual(ledger.residentBytes, 40)
        withExtendedLifetime(next) {}
    }
    func testAlignedReconciliationCannotExceedBudget() throws {
        let ledger = ProcessingResourceLedger(limits: .init(maxResidentBytes: 100), policy: .init())
        let charge = try ledger.reserve(70)
        try charge.reconcile(90)
        XCTAssertThrowsError(try charge.reconcile(101))
        XCTAssertEqual(charge.bytes, 90)
        XCTAssertEqual(ledger.residentBytes, 90)
    }
}
