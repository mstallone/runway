import os
import XCTest
@testable import Runway

// MARK: - Client request contract

final class CursorUsageClientRequestTests: XCTestCase {
    // Pin the request contract directly at the client level — endpoint, epoch-ms range,
    // `strategy=tokens`, the session cookie, and `Accept: text/csv` — so a silent regression in
    // URL/header construction cannot slip through.
    func testFetchUsageCSVStopsAStreamingExportAtItsDeadline() async {
        // The export keeps the connection busy, so the request timeout never fires. The client's
        // deadline has to end it and cancel the request in flight.
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        let http = RoutingHTTPClient { _ in
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                cancelled.withLock { $0 = true }
                throw error
            }
            return HTTPResponse(statusCode: 200, headers: [:], body: Data("Date,Model,Cost\n".utf8))
        }
        let clock = ContinuousClock()
        let started = clock.now

        do {
            _ = try await CursorUsageClient(http: http).fetchUsageCSV(
                accessToken: makeCursorJWT(sub: "google-oauth2|user_abc123"),
                start: Date(timeIntervalSince1970: 1_799_000_000),
                end: Date(timeIntervalSince1970: 1_800_000_000),
                deadline: 0.05
            )
            XCTFail("expected the deadline to end the export")
        } catch {
            XCTAssertTrue(error is DeadlineExceeded, "\(error)")
        }

        XCTAssertEqual(http.requests.count, 1)
        XCTAssertLessThan(started.duration(to: clock.now), .seconds(5))
        XCTAssertTrue(cancelled.withLock { $0 }, "the in-flight CSV request must be cancelled")
    }

    func testFetchUsageCSVBuildsTokenStrategyRequestWithSessionCookie() async throws {
        let accessToken = makeCursorJWT(sub: "google-oauth2|user_abc123")
        let http = RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 200, headers: [:], body: Data("Date,Model\n".utf8))
        }

        let response = try await CursorUsageClient(http: http).fetchUsageCSV(
            accessToken: accessToken,
            start: Date(timeIntervalSince1970: 1_000),   // 1_000_000 ms
            end: Date(timeIntervalSince1970: 2_000),     // 2_000_000 ms
            deadline: 30
        )

        XCTAssertEqual(response?.statusCode, 200)
        // A nil session would skip the HTTP call entirely, so requiring a recorded request guards that
        // the assertions below actually ran against a real request.
        let request = try XCTUnwrap(http.requests.first, "fetchUsageCSV must issue a request")
        let url = request.url.absoluteString
        XCTAssertTrue(url.contains("export-usage-events-csv"), "hits the CSV export endpoint")
        XCTAssertTrue(url.contains("startDate=1000000"), "start as epoch-ms query param")
        XCTAssertTrue(url.contains("endDate=2000000"), "end as epoch-ms query param")
        XCTAssertTrue(url.contains("strategy=tokens"), "token strategy")
        XCTAssertEqual(request.headers["Cookie"], "WorkosCursorSessionToken=user_abc123%3A%3A\(accessToken)")
        XCTAssertEqual(request.headers["Accept"], "text/csv")
    }
}

private func makeCursorJWT(sub: String = "google-oauth2|user", exp: Double = 9_999_999_999) -> String {
    let payload = #"{"sub":"\#(sub)","exp":\#(exp)}"#
    let encoded = Data(payload.utf8).base64EncodedString()
        .replacingOccurrences(of: "=", with: "")
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
    return "a.\(encoded).c"
}
