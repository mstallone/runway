import XCTest
@testable import Runway

/// Go plan meters from `/zen/go/v1/usage`: percent format, resets, periods, and boundary failures.
final class OpenCodeUsageMapperTests: XCTestCase {
    private let sampleBody: [String: Any] = [
        "usage": [
            "rolling": ["status": "ok", "percent": 12, "resetsAt": "2026-07-12T13:30:00.662Z"],
            "weekly": ["status": "ok", "percent": 8, "resetsAt": "2026-07-13T00:00:00.662Z"],
            "monthly": ["status": "rate-limited", "percent": 100, "resetsAt": "2026-08-04T11:18:32.662Z"]
        ]
    ]
    /// Mid-window relative to every reset in `sampleBody`, so no fixture reads as a placeholder.
    private let capturedAt = RunwayISO8601.date(from: "2026-07-12T12:00:00.000Z")!
    private let sessionPeriod = TimeInterval(MetricPeriod.sessionMs) / 1000

    /// A usage body whose rolling window reads 0% with `rollingReset`, and ordinary weekly/monthly rows.
    private func zeroUsageBody(rollingReset: Date) -> [String: Any] {
        [
            "usage": [
                "rolling": ["percent": 0, "resetsAt": RunwayISO8601.string(from: rollingReset)],
                "weekly": ["percent": 1, "resetsAt": RunwayISO8601.string(from: capturedAt.addingTimeInterval(3 * 86_400))],
                "monthly": ["percent": 0, "resetsAt": RunwayISO8601.string(from: capturedAt.addingTimeInterval(20 * 86_400))]
            ]
        ]
    }

    private func sessionReset(_ lines: [MetricLine], file: StaticString = #filePath, line: UInt = #line) -> Date? {
        guard case let .progress(_, _, _, _, resetsAt, _, _) = lines[0] else {
            XCTFail("session is not a progress line", file: file, line: line)
            return nil
        }
        return resetsAt
    }

    func testMeterLinesMatchDashboardPercentsAndResets() throws {
        let lines = try OpenCodeUsageMapper.meterLines(body: sampleBody, capturedAt: capturedAt)
        XCTAssertEqual(lines.map(\.label), ["Session", "Weekly", "Monthly"])

        guard case let .progress(_, sessionUsed, sessionLimit, sessionFormat, sessionReset, sessionPeriod, _) = lines[0] else {
            return XCTFail("session is not a progress line")
        }
        XCTAssertEqual(sessionUsed, 12)
        XCTAssertEqual(sessionLimit, 100)
        XCTAssertEqual(sessionFormat, .percent)
        XCTAssertEqual(sessionReset, RunwayISO8601.date(from: "2026-07-12T13:30:00.662Z"))
        XCTAssertEqual(sessionPeriod, MetricPeriod.sessionMs)

        guard case let .progress(_, weeklyUsed, _, weeklyFormat, weeklyReset, weeklyPeriod, _) = lines[1] else {
            return XCTFail("weekly is not a progress line")
        }
        XCTAssertEqual(weeklyUsed, 8)
        XCTAssertEqual(weeklyFormat, .percent)
        XCTAssertEqual(weeklyReset, RunwayISO8601.date(from: "2026-07-13T00:00:00.662Z"))
        XCTAssertEqual(weeklyPeriod, MetricPeriod.weekMs)

        guard case let .progress(_, monthlyUsed, _, monthlyFormat, _, monthlyPeriod, _) = lines[2] else {
            return XCTFail("monthly is not a progress line")
        }
        XCTAssertEqual(monthlyUsed, 100)
        XCTAssertEqual(monthlyFormat, .percent)
        XCTAssertEqual(monthlyPeriod, MetricPeriod.monthMs)
    }

    func testZeroPercentIsARealMeterNotNoData() throws {
        let body: [String: Any] = [
            "usage": [
                "rolling": ["percent": 0, "resetsAt": "2026-07-12T17:00:00.000Z"],
                "weekly": ["percent": 0, "resetsAt": "2026-07-13T00:00:00.000Z"],
                "monthly": ["percent": 0, "resetsAt": "2026-08-04T00:00:00.000Z"]
            ]
        ]
        let lines = try OpenCodeUsageMapper.meterLines(body: body, capturedAt: capturedAt)
        guard case let .progress(_, used, limit, format, _, _, _) = lines[0] else {
            return XCTFail("session is not a progress line")
        }
        XCTAssertEqual(used, 0)
        XCTAssertEqual(limit, 100)
        XCTAssertEqual(format, .percent)
    }

    /// An untouched rolling window has nothing to roll off, so the API answers `resetsAt = now + 5h`
    /// and slides it forward on every request. The mapper drops that placeholder so the Session row
    /// reads "Not started" off the missing reset.
    func testUntouchedRollingWindowDropsPlaceholderReset() throws {
        let placeholder = capturedAt.addingTimeInterval(sessionPeriod + 0.8)
        let lines = try OpenCodeUsageMapper.meterLines(
            body: zeroUsageBody(rollingReset: placeholder), capturedAt: capturedAt
        )
        guard case let .progress(_, used, _, _, resetsAt, _, _) = lines[0] else {
            return XCTFail("session is not a progress line")
        }
        XCTAssertEqual(used, 0)
        XCTAssertNil(resetsAt)
    }

    /// The reported bug: a session that has started still reads 0% (whole-percent API), but its reset
    /// is already anchored inside the five-hour period and must survive.
    func testSubOnePercentRollingWindowKeepsAnchoredReset() throws {
        for age in [30.0, 60.0, 4 * 3600.0] {
            let anchored = capturedAt.addingTimeInterval(sessionPeriod - age)
            let lines = try OpenCodeUsageMapper.meterLines(
                body: zeroUsageBody(rollingReset: anchored), capturedAt: capturedAt
            )
            XCTAssertEqual(sessionReset(lines), anchored, "active session aged \(age)s lost its reset")
        }
    }

    func testPlaceholderComparisonIsBoundedOnBothSides() throws {
        func mappedReset(offsetFromFullPeriod offset: TimeInterval) throws -> Date? {
            let reset = capturedAt.addingTimeInterval(sessionPeriod + offset)
            return sessionReset(try OpenCodeUsageMapper.meterLines(
                body: zeroUsageBody(rollingReset: reset), capturedAt: capturedAt
            ))
        }
        let tolerance = OpenCodeUsageMapper.placeholderResetTolerance
        XCTAssertNil(try mappedReset(offsetFromFullPeriod: -tolerance))
        XCTAssertNil(try mappedReset(offsetFromFullPeriod: tolerance))
        XCTAssertNotNil(try mappedReset(offsetFromFullPeriod: -tolerance - 0.5))
        XCTAssertNotNil(try mappedReset(offsetFromFullPeriod: tolerance + 0.5))
        XCTAssertNotNil(try mappedReset(offsetFromFullPeriod: 5 * 60), "a distant reset is not a placeholder")
    }

    /// A full-period reset on a window with usage is a real reset, never a placeholder.
    func testFullPeriodResetWithUsageIsKept() throws {
        let reset = capturedAt.addingTimeInterval(sessionPeriod)
        var body = zeroUsageBody(rollingReset: reset)
        var usage = try XCTUnwrap(body["usage"] as? [String: Any])
        usage["rolling"] = ["percent": 1, "resetsAt": RunwayISO8601.string(from: reset)]
        body["usage"] = usage
        XCTAssertEqual(sessionReset(try OpenCodeUsageMapper.meterLines(body: body, capturedAt: capturedAt)), reset)
    }

    func testHTTPDateHeaderWinsOverSkewedLocalClock() throws {
        let serverDate = RunwayISO8601.date(from: "2027-01-15T08:00:00.000Z")!
        var body = zeroUsageBody(rollingReset: serverDate.addingTimeInterval(sessionPeriod + 0.5))
        let data = try JSONSerialization.data(withJSONObject: body)
        // The local clock is two minutes fast. Only the server date identifies the placeholder.
        let skewedLocal = serverDate.addingTimeInterval(2 * 60)
        let withHeader = HTTPResponse(statusCode: 200, headers: ["date": "Fri, 15 Jan 2027 08:00:00 GMT"], body: data)
        XCTAssertNil(sessionReset(try OpenCodeUsageMapper.meterLines(withHeader, capturedAt: skewedLocal)))

        // And the reverse: an anchored reset stays even when the skewed local clock makes it look
        // exactly one period away.
        let anchored = serverDate.addingTimeInterval(sessionPeriod - 120)
        body = zeroUsageBody(rollingReset: anchored)
        let anchoredResponse = HTTPResponse(
            statusCode: 200,
            headers: ["date": "Fri, 15 Jan 2027 08:00:00 GMT"],
            body: try JSONSerialization.data(withJSONObject: body)
        )
        XCTAssertEqual(
            sessionReset(try OpenCodeUsageMapper.meterLines(
                anchoredResponse, capturedAt: serverDate.addingTimeInterval(-120)
            )),
            anchored
        )
    }

    func testMissingOrMalformedHTTPDateFallsBackToCapturedAt() throws {
        let body = zeroUsageBody(rollingReset: capturedAt.addingTimeInterval(sessionPeriod + 0.5))
        let data = try JSONSerialization.data(withJSONObject: body)
        for headers in [[:], ["date": "not-an-http-date"]] {
            let response = HTTPResponse(statusCode: 200, headers: headers, body: data)
            XCTAssertNil(sessionReset(try OpenCodeUsageMapper.meterLines(response, capturedAt: capturedAt)))
        }
    }

    /// Weekly and monthly resets are calendar and billing instants that exist with or without usage.
    /// Early in a cycle one sits a full period out, and it must keep its countdown.
    func testFullPeriodWeeklyAndMonthlyResetsSurviveAtZeroUsage() throws {
        let weeklyReset = capturedAt.addingTimeInterval(TimeInterval(MetricPeriod.weekMs) / 1000)
        let monthlyReset = capturedAt.addingTimeInterval(TimeInterval(MetricPeriod.monthMs) / 1000)
        let body: [String: Any] = [
            "usage": [
                "rolling": ["percent": 0, "resetsAt": RunwayISO8601.string(from: capturedAt.addingTimeInterval(2 * 3600))],
                "weekly": ["percent": 0, "resetsAt": RunwayISO8601.string(from: weeklyReset)],
                "monthly": ["percent": 0, "resetsAt": RunwayISO8601.string(from: monthlyReset)]
            ]
        ]
        let lines = try OpenCodeUsageMapper.meterLines(body: body, capturedAt: capturedAt)
        guard case let .progress(_, _, _, _, weekly, _, _) = lines[1],
              case let .progress(_, _, _, _, monthly, _, _) = lines[2] else {
            return XCTFail("expected progress lines")
        }
        XCTAssertEqual(weekly, weeklyReset)
        XCTAssertEqual(monthly, monthlyReset)
    }

    /// The rolling session without a usable `resetsAt` fails loudly, at any usage. Accepting it would
    /// make a malformed session reset indistinguishable from an untouched window.
    func testMissingOrMalformedRollingResetIsInvalid() {
        let rollingWindows: [[String: Any]] = [
            ["percent": 0], ["percent": 0, "resetsAt": "not-a-date"], ["percent": 12, "resetsAt": 5]
        ]
        for rolling in rollingWindows {
            let body: [String: Any] = [
                "usage": [
                    "rolling": rolling,
                    "weekly": ["percent": 0, "resetsAt": "2027-01-18T00:00:00.000Z"],
                    "monthly": ["percent": 0, "resetsAt": "2027-02-10T08:00:00.000Z"]
                ]
            ]
            XCTAssertThrowsError(try OpenCodeUsageMapper.meterLines(body: body, capturedAt: capturedAt)) { error in
                XCTAssertEqual(error as? OpenCodeUsageError, .invalidResponse)
            }
        }
    }

    /// Weekly and monthly have no "Not started" state to confuse, so a missing or malformed reset
    /// keeps the meter and only loses the countdown. The other windows are unaffected.
    func testWeeklyAndMonthlyWithoutAResetStillMap() throws {
        let rollingReset = capturedAt.addingTimeInterval(2 * 3600)
        let body: [String: Any] = [
            "usage": [
                "rolling": ["percent": 7, "resetsAt": RunwayISO8601.string(from: rollingReset)],
                "weekly": ["percent": 8],
                "monthly": ["percent": 35, "resetsAt": "not-a-date"]
            ]
        ]
        let lines = try OpenCodeUsageMapper.meterLines(body: body, capturedAt: capturedAt)
        guard case let .progress(_, weeklyUsed, _, _, weeklyReset, weeklyPeriod, _) = lines[1],
              case let .progress(_, monthlyUsed, _, _, monthlyReset, monthlyPeriod, _) = lines[2] else {
            return XCTFail("expected progress lines")
        }
        XCTAssertEqual(sessionReset(lines), rollingReset)
        XCTAssertEqual(weeklyUsed, 8)
        XCTAssertNil(weeklyReset)
        XCTAssertEqual(weeklyPeriod, MetricPeriod.weekMs)
        XCTAssertEqual(monthlyUsed, 35)
        XCTAssertNil(monthlyReset)
        XCTAssertEqual(monthlyPeriod, MetricPeriod.monthMs)
    }

    func testPercentIsClamped() throws {
        let body: [String: Any] = [
            "usage": [
                "rolling": ["percent": 150, "resetsAt": "2026-07-12T13:30:00.662Z"],
                "weekly": ["percent": -4, "resetsAt": "2026-07-13T00:00:00.662Z"],
                "monthly": ["percent": 35, "resetsAt": "2026-08-04T11:18:32.662Z"]
            ]
        ]
        let lines = try OpenCodeUsageMapper.meterLines(body: body, capturedAt: capturedAt)
        guard case let .progress(_, rolling, _, _, _, _, _) = lines[0],
              case let .progress(_, weekly, _, _, _, _, _) = lines[1] else {
            return XCTFail("expected progress lines")
        }
        XCTAssertEqual(rolling, 100)
        XCTAssertEqual(weekly, 0)
    }

    func testHTTPResponseBodyRoundTrip() throws {
        let data = try JSONSerialization.data(withJSONObject: sampleBody)
        let lines = try OpenCodeUsageMapper.meterLines(HTTPResponse(statusCode: 200, headers: [:], body: data), capturedAt: capturedAt)
        XCTAssertEqual(lines.count, 3)
    }

    func testMissingUsageOrWindowIsInvalid() {
        XCTAssertThrowsError(try OpenCodeUsageMapper.meterLines(body: [:], capturedAt: capturedAt)) { error in
            XCTAssertEqual(error as? OpenCodeUsageError, .invalidResponse)
        }
        XCTAssertThrowsError(try OpenCodeUsageMapper.meterLines(body: ["usage": ["weekly": ["percent": 1]]], capturedAt: capturedAt)) { error in
            XCTAssertEqual(error as? OpenCodeUsageError, .invalidResponse)
        }
    }

    func testErrorTypeFromDocumentedErrorBody() {
        let entitlement = """
        {"type":"error","error":{"type":"EntitlementError","message":"OpenCode Go subscription required."}}
        """.data(using: .utf8)!
        let auth = """
        {"type":"error","error":{"type":"AuthError","message":"Unauthorized"}}
        """.data(using: .utf8)!
        XCTAssertEqual(
            OpenCodeUsageMapper.errorType(in: HTTPResponse(statusCode: 403, headers: [:], body: entitlement)),
            "EntitlementError"
        )
        XCTAssertEqual(
            OpenCodeUsageMapper.errorType(in: HTTPResponse(statusCode: 401, headers: [:], body: auth)),
            "AuthError"
        )
        XCTAssertNil(OpenCodeUsageMapper.errorType(in: HTTPResponse(statusCode: 403, headers: [:], body: Data("<html>".utf8))))
    }
}
