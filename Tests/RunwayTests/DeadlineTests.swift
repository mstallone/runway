import os
import XCTest
@testable import Runway

final class DeadlineTests: XCTestCase {
    func testSlowOperationThrowsAtTheDeadlineAndIsCancelled() async {
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        let clock = ContinuousClock()
        let started = clock.now

        do {
            _ = try await withDeadline(seconds: 0.05) {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    cancelled.withLock { $0 = true }
                    throw error
                }
                return 1
            }
            XCTFail("expected the deadline to win")
        } catch {
            XCTAssertTrue(error is DeadlineExceeded, "\(error)")
        }

        XCTAssertLessThan(started.duration(to: clock.now), .seconds(5))
        XCTAssertTrue(cancelled.withLock { $0 }, "the in-flight operation must be cancelled")
    }

    func testFastOperationReturnsItsValue() async throws {
        let value = try await withDeadline(seconds: 30) { "done" }
        XCTAssertEqual(value, "done")
    }

    func testOperationErrorIsNotReportedAsADeadline() async {
        do {
            _ = try await withDeadline(seconds: 30) { () async throws -> Int in throw HTTPClientError.invalidResponse }
            XCTFail("expected the operation's error")
        } catch {
            XCTAssertFalse(error is DeadlineExceeded, "\(error)")
        }
    }
}
