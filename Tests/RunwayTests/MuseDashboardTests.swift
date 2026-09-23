import XCTest
@testable import Runway

final class MuseUsageMapperTests: XCTestCase {
    func testWeightedStringAmountsMapToPercentagesAndResets() throws {
        let mapped = try MuseUsageMapper.map(Data(musePage().utf8))
        XCTAssertEqual(mapped.plan, "Power Usage")
        XCTAssertEqual(mapped.observedAt, museNow.addingTimeInterval(-30))
        guard case .progress(_, let used, let limit, let format, let resetsAt, let duration, _) = mapped.lines[0] else {
            return XCTFail("Missing window")
        }
        XCTAssertEqual(used, 12)
        XCTAssertEqual(limit, 100)
        XCTAssertEqual(format, .percent)
        XCTAssertEqual(resetsAt, Date(timeIntervalSince1970: 1_800_005_000))
        XCTAssertEqual(duration, MetricPeriod.sessionMs)
    }

    func testZeroAndOverQuotaAreValidButNegativeAmountsAreNot() throws {
        let zero = try MuseUsageMapper.map(Data(musePage(["window_weighted_used": 0]).utf8))
        guard case .progress(_, let used, _, _, _, _, _) = zero.lines[0] else { return XCTFail() }
        XCTAssertEqual(used, 0)
        let over = try MuseUsageMapper.map(Data(musePage(["window_weighted_used": 400]).utf8))
        guard case .progress(_, let overUsed, _, _, _, _, _) = over.lines[0] else { return XCTFail() }
        XCTAssertEqual(overUsed, 100)
        XCTAssertThrowsError(try MuseUsageMapper.map(Data(musePage(["window_weighted_used": -1]).utf8)))
    }

    func testRejectsIncompleteInvalidAndBooleanQuotaWithoutInventingZero() {
        for overrides: [String: Any] in [
            ["window_weighted_limit": 0], ["weekly_weighted_used": NSNull()],
            ["weekly_weighted_limit": "NaN"], ["window_weighted_used": true],
            ["window_weighted_limit": "Infinity"], ["window_weighted_used": "1e309"]
        ] {
            XCTAssertThrowsError(try MuseUsageMapper.map(Data(musePage(overrides).utf8))) {
                XCTAssertEqual($0 as? MuseUsageError, .invalidResponse)
            }
        }
    }

    func testMissingQuotaIsUnavailableButMalformedObjectIsInvalid() {
        for page in ["<html>login or changed dashboard</html>", #"{"subscription_quota_usage":null}"#] {
            XCTAssertThrowsError(try MuseUsageMapper.map(Data(page.utf8))) {
                XCTAssertEqual($0 as? MuseUsageError, .quotaUnavailable)
            }
        }
        for page in [#"{"subscription_quota_usage":{"tier":"test"}"#, #"{"subscription_quota_usage":[]}"#] {
            XCTAssertThrowsError(try MuseUsageMapper.map(Data(page.utf8))) {
                XCTAssertEqual($0 as? MuseUsageError, .invalidResponse)
            }
        }
    }

    func testBracesAndEscapedQuotesInsideStringsDoNotTruncateObject() throws {
        let mapped = try MuseUsageMapper.map(Data(musePage(["extra": "a\"}b\\c{"]).utf8))
        XCTAssertEqual(mapped.lines.count, 2)
    }

    func testOpaqueTierAndInvalidDateAreOmitted() throws {
        let mapped = try MuseUsageMapper.map(Data(musePage([
            "tier": "123456789", "as_of": -1, "window_resets_at": "1e99"
        ]).utf8))
        XCTAssertNil(mapped.plan)
        XCTAssertNil(mapped.observedAt)
        guard case .progress(_, _, _, _, let reset, _, _) = mapped.lines[0] else { return XCTFail() }
        XCTAssertNil(reset)
    }

    func testDisplayPlanStripsOnlyProviderPrefix() {
        XCTAssertEqual(MuseUsageMapper.displayPlan("Muse Code Power Usage"), "Power Usage")
        XCTAssertEqual(MuseUsageMapper.displayPlan("High Usage"), "High Usage")
        XCTAssertNil(MuseUsageMapper.displayPlan("  "))
    }
}

final class MuseAuthStoreTests: XCTestCase {
    func testReadsOnlyExactMetaHostsAndSessionCookieWithoutCLIKeychain() throws {
        let rows = MuseCookieRows()
        let store = museAuth(rows: rows)
        XCTAssertTrue(store.hasCredentialFootprint())
        XCTAssertEqual(try store.loadSession(allowInteraction: false).token, museToken)
        XCTAssertTrue(rows.queries.allSatisfy { $0.contains("name = 'llm_sess'") })
        XCTAssertTrue(rows.queries.allSatisfy { $0.contains("host_key IN ('dev.meta.ai', '.dev.meta.ai', 'meta.ai', '.meta.ai')") })
        XCTAssertFalse(rows.queries.contains { $0.contains("LIKE") })
    }

    func testRejectsAnUnrelatedHostEvenIfDatabaseReturnsIt() {
        for host in ["evilmeta.ai", "meta.ai.attacker.test", "console.sakana.ai"] {
            let store = museAuth(rows: MuseCookieRows(host: host))
            XCTAssertThrowsError(try store.loadSession(allowInteraction: false)) {
                XCTAssertEqual($0 as? MuseAuthError, .invalidCredentialData)
            }
            XCTAssertFalse(store.hasCredentialFootprint())
        }
    }

    func testMissingCookieRequestsDashboardLogin() {
        let store = museAuth(rows: MuseCookieRows(token: nil))
        XCTAssertFalse(store.hasCredentialFootprint())
        XCTAssertThrowsError(try store.loadSession(allowInteraction: false)) {
            XCTAssertEqual($0 as? MuseAuthError, .notLoggedIn)
        }
    }

    func testDeferredAndDeniedSafeStorageReadsKeepDistinctMessages() {
        let rows = MuseCookieRows(token: "v10ciphertext", encrypted: true)
        XCTAssertTrue(museAuth(rows: rows).hasCredentialFootprint())
        for (error, expected) in [
            (SakanaBrowserCredentialError.manualReadDeferred, MuseAuthError.keychainConnectRequired),
            (.permissionRequired, .keychainPermissionRequired),
            (.keychainFailure(-1), .credentialStoreUnreadable)
        ] {
            let store = museAuth(rows: rows, keyReader: MuseNoKeyReader(error: error))
            XCTAssertThrowsError(try store.loadSession(allowInteraction: false)) {
                XCTAssertEqual($0 as? MuseAuthError, expected)
            }
        }
    }
}

final class MuseDashboardRedirectTests: XCTestCase {
    func testAllowsTeamRedirectAndPreservesCookieOnSameHTTPSHost() throws {
        var original = URLRequest(url: MuseUsageClient.usageURL)
        original.setValue("llm_sess=fixture", forHTTPHeaderField: "Cookie")
        let proposed = URLRequest(url: URL(string: "https://dev.meta.ai/usage/?team_id=1&project_id=2")!)
        let accepted = try XCTUnwrap(MuseDashboardRedirects.request(proposed, original: original))
        XCTAssertEqual(accepted.value(forHTTPHeaderField: "Cookie"), "llm_sess=fixture")
    }

    func testDoesNotForwardCookieToLoginOtherHostsOrHTTP() {
        let original = URLRequest(url: MuseUsageClient.usageURL)
        for address in [
            "https://auth.meta.com/login", "https://dev.meta.ai.attacker.test/", "http://dev.meta.ai/usage/",
            "https://dev.meta.ai:8443/", "https://user@dev.meta.ai/",
            "https://dev.meta.ai/", "https://dev.meta.ai/login/"
        ] {
            XCTAssertNil(MuseDashboardRedirects.request(URLRequest(url: URL(string: address)!), original: original))
        }
    }
}
