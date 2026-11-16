import XCTest
import Dispatch
import ImagingCore

final class UnfairLockTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        var value = 0 // Every access during concurrent execution is guarded by the shared lock.
    }

    func testCopiesAndManualLockingShareMutualExclusion() {
        let lock = UnfairLock(), copy = lock, counter = Counter()
        DispatchQueue.concurrentPerform(iterations: 10_000) { index in
            if index.isMultiple(of: 2) {
                lock.withLock { counter.value += 1 }
            } else {
                copy.lock(); defer { copy.unlock() }
                counter.value += 1
            }
        }
        XCTAssertEqual(counter.value, 10_000)
    }

    func testThrowingOperationUnlocksAndReturnsValues() {
        enum Failure: Error { case expected }
        let lock = UnfairLock()
        XCTAssertThrowsError(try lock.withLock { throw Failure.expected })
        XCTAssertEqual(lock.withLock { 42 }, 42)
    }
}
