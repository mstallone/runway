import XCTest
@testable import Runway

@MainActor
final class MuseProviderTests: XCTestCase {
    func testReadsDashboardWithCookieAndNeverMintsOrInfers() async {
        let http = museHTTP { request in
            XCTAssertEqual(request.method, "GET")
            XCTAssertEqual(request.url, museQuotaURL)
            XCTAssertEqual(request.headers["Cookie"], "llama_dev_sess=\(museToken)")
            XCTAssertEqual(request.headers["Accept"], "application/json")
            XCTAssertNil(request.headers["Authorization"])
            XCTAssertNil(request.body)
            return museResponse()
        }
        let snapshot = await makeMuseProvider(http: http).refresh()
        XCTAssertEqual(snapshot.plan, "Power Usage")
        XCTAssertEqual(snapshot.loginRequired, false)
        XCTAssertEqual(museUsed(snapshot), 12)
        XCTAssertEqual(museUsed(snapshot, label: "Weekly Usage"), 34)
        XCTAssertEqual(snapshot.refreshedAt, museNow.addingTimeInterval(-30))
        XCTAssertEqual(http.requests.count, 2)
    }

    func testManualAndAutomaticRefreshesShareTheMinimumInterval() async {
        let clock = MuseTestClock()
        let http = museHTTP { _ in museResponse() }
        let provider = makeMuseProvider(http: http, now: { clock.now })
        _ = await provider.refresh()
        clock.now = museNow.addingTimeInterval(60)
        _ = await ProviderRefreshContext.$isManual.withValue(true) { await provider.refresh() }
        XCTAssertEqual(http.requests.count, 2)
        clock.now = museNow.addingTimeInterval(MuseProvider.minimumRefreshInterval)
        _ = await provider.refresh()
        XCTAssertEqual(http.requests.count, 4)
    }

    func testConcurrentRefreshesShareOneFetch() async {
        let http = museHTTP { _ in museResponse() }
        let provider = makeMuseProvider(http: http)
        async let first = provider.refresh()
        async let second = provider.refresh()
        let snapshots = await [first, second]
        XCTAssertEqual(snapshots[0], snapshots[1])
        XCTAssertEqual(http.requests.count, 2)
    }

    func testRateLimitPreservesMeasurementAndHonorsLongRetryAfter() async {
        let clock = MuseTestClock()
        let http = museHTTP { _ in
            if clock.now == museNow { return museResponse() }
            return museResponse("", status: 429, headers: ["retry-after": "7200"])
        }
        let provider = makeMuseProvider(http: http, now: { clock.now })
        let first = await provider.refresh()
        clock.now = museNow.addingTimeInterval(900)
        let stale = await provider.refresh()
        XCTAssertEqual(stale.refreshedAt, first.refreshedAt)
        XCTAssertEqual(museUsed(stale), 12)
        XCTAssertEqual(stale.warningAction, .wait)
        XCTAssertNil(stale.loginRequired)
        clock.now = museNow.addingTimeInterval(4500)
        _ = await ProviderRefreshContext.$isManual.withValue(true) { await provider.refresh() }
        XCTAssertEqual(http.requests.count, 4)
        clock.now = museNow.addingTimeInterval(8100)
        _ = await provider.refresh()
        XCTAssertEqual(http.requests.count, 6)
    }

    func testHTTPDateRetryAfterWithNoPreviousMeasurement() async {
        let clock = MuseTestClock()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let retry = formatter.string(from: museNow.addingTimeInterval(3600))
        let http = museHTTP { _ in museResponse("", status: 429, headers: ["retry-after": retry]) }
        let provider = makeMuseProvider(http: http, now: { clock.now })
        let snapshot = await provider.refresh()
        XCTAssertNil(museUsed(snapshot))
        clock.now = museNow.addingTimeInterval(1800)
        _ = await provider.refresh()
        XCTAssertEqual(http.requests.count, 2)
        clock.now = museNow.addingTimeInterval(3600)
        _ = await provider.refresh()
        XCTAssertEqual(http.requests.count, 4)
    }

    func testAuthRejectionClearsOldMetersAndStillThrottlesRetries() async {
        let clock = MuseTestClock()
        let http = museHTTP { _ in clock.now == museNow ? museResponse() : museResponse("", status: 401) }
        let provider = makeMuseProvider(http: http, now: { clock.now })
        _ = await provider.refresh()
        clock.now = museNow.addingTimeInterval(900)
        let expired = await provider.refresh()
        XCTAssertNil(museUsed(expired))
        XCTAssertTrue(expired.lines.contains(where: \.isError))
        _ = await provider.refresh()
        XCTAssertEqual(http.requests.count, 4)
    }

    func testBrowserAccountChangeNeverInheritsOldQuotaOrCooldown() async {
        let rows = MuseCookieRows()
        let http = museHTTP { request in
            request.headers["Cookie"] == "llama_dev_sess=\(museToken)" ? museResponse() : museResponse("", status: 503)
        }
        let provider = makeMuseProvider(http: http, rows: rows)
        _ = await provider.refresh()
        rows.row = MuseCookieRows(token: String(repeating: "new-account", count: 5)).row
        let changed = await provider.refresh()
        XCTAssertNil(museUsed(changed))
        XCTAssertNil(changed.plan)
        XCTAssertEqual(http.requests.count, 4)
    }

    func testLogoutDropsPreviousMetersWithoutCallingNetwork() async {
        let rows = MuseCookieRows()
        let http = museHTTP { _ in museResponse() }
        let provider = makeMuseProvider(http: http, rows: rows)
        _ = await provider.refresh()
        rows.row = nil
        let loggedOut = await provider.refresh()
        XCTAssertNil(museUsed(loggedOut))
        XCTAssertEqual(http.requests.count, 2)
    }

    func testMissingQuotaRetainsOldObservationWithWarningNotZero() async {
        let clock = MuseTestClock()
        let http = museHTTP { _ in clock.now == museNow ? museResponse() : museResponse("<html>changed page</html>") }
        let provider = makeMuseProvider(http: http, now: { clock.now })
        let first = await provider.refresh()
        clock.now = museNow.addingTimeInterval(900)
        let stale = await provider.refresh()
        XCTAssertEqual(stale.refreshedAt, first.refreshedAt)
        XCTAssertEqual(museUsed(stale), 12)
        XCTAssertNotNil(stale.warning)
    }

    func testLocalHistoryLoadsWithQuotaAndWithoutBrowserLogin() async throws {
        let scanner = try museLogScanner(tokens: 1_000_000)
        let http = museHTTP { _ in museResponse() }
        let provider = makeMuseProvider(http: http, logUsageScanner: scanner)
        let snapshot = await provider.refresh()
        XCTAssertEqual(museUsed(snapshot), 12)
        XCTAssertNotNil(snapshot.line(label: "Today"))
        XCTAssertEqual(snapshot.usageHistory?.series.daily.first?.totalTokens, 1_000_000)
        let local = makeMuseProvider(http: http, rows: MuseCookieRows(token: nil), logUsageScanner: scanner)
        let detected = await local.hasLocalCredentials()
        XCTAssertTrue(detected)
        let localSnapshot = await local.refresh()
        XCTAssertNil(museUsed(localSnapshot))
        XCTAssertNotNil(localSnapshot.line(label: "Today"))
        XCTAssertNotNil(localSnapshot.warning)
        XCTAssertEqual(http.requests.count, 2)
    }

    func testExpiredNewerProfileFallsThroughAndIsNotRetriedOnEveryRefresh() async {
        let rows = MuseCookieRows()
        let expired = String(repeating: "expired-profile", count: 4)
        rows.rowsByPath = [
            "/profiles/new/Cookies": MuseCookieRows(token: expired, updatedAt: 99).row!,
            "/profiles/old/Cookies": MuseCookieRows().row!
        ]
        let http = museHTTP { request in
            request.headers["Cookie"] == "llama_dev_sess=\(expired)" ? museResponse("", status: 401) : museResponse()
        }
        let provider = makeMuseProvider(http: http, rows: rows)
        let snapshot = await provider.refresh()
        XCTAssertEqual(museUsed(snapshot), 12)
        XCTAssertEqual(http.requests.count, 4)
        _ = await provider.refresh()
        XCTAssertEqual(http.requests.count, 4)
    }

    func testRateLimitDoesNotTryAnotherBrowserProfile() async {
        let rows = MuseCookieRows()
        rows.rowsByPath = [
            "/profiles/new/Cookies": MuseCookieRows(updatedAt: 99).row!,
            "/profiles/old/Cookies": MuseCookieRows(token: String(repeating: "other", count: 9)).row!
        ]
        let http = museHTTP { _ in museResponse("", status: 429) }
        let provider = makeMuseProvider(http: http, rows: rows)
        let snapshot = await provider.refresh()
        XCTAssertNil(museUsed(snapshot))
        XCTAssertEqual(http.requests.count, 2)
    }

    func testLocalHistoryAfterNetworkFailureDoesNotVerifyLoginRecovery() async throws {
        let scanner = try museLogScanner(tokens: 500_000)
        let http = museHTTP { _ in throw URLError(.notConnectedToInternet) }
        let provider = makeMuseProvider(http: http, logUsageScanner: scanner)
        let snapshot = await provider.refresh()
        XCTAssertNotNil(snapshot.warning)
        XCTAssertNotNil(snapshot.line(label: "Today"))
        XCTAssertNil(snapshot.loginRequired)
    }

    func testConnectPromptStillLoadsLocalHistoryWithoutNetwork() async throws {
        let http = museHTTP { _ in XCTFail("Must not fetch without a browser session"); return museResponse() }
        let provider = makeMuseProvider(
            http: http, rows: MuseCookieRows(token: "v10ciphertext", encrypted: true),
            logUsageScanner: try museLogScanner(tokens: 42)
        )
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.warningIsConnectPrompt, true)
        XCTAssertNotNil(snapshot.line(label: "Today"))
        XCTAssertTrue(http.requests.isEmpty)
    }
}
