import SwiftUI
import XCTest
@testable import Runway

/// The Claude "Rate Limit Resets" row, read from the usage body's `cedar_ember` block (Anthropic's
/// one-off usage-limit reset grants). Read-only: Claude never gets a claim flow.
@MainActor
final class ClaudeResetGrantsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21

    private func resetsLine(_ json: String) throws -> MetricLine? {
        let response = HTTPResponse(statusCode: 200, headers: [:], body: Data(json.utf8))
        let mapped = try ClaudeUsageMapper.mapUsageResponse(
            response, credentials: ClaudeOAuth(subscriptionType: "max"), now: now
        )
        return Self.resetsLine(in: mapped.lines)
    }

    private static func resetsLine(in lines: [MetricLine]) -> MetricLine? {
        lines.first { line in
            if case .values(let label, _, _, _, _, _) = line { return label == "Rate Limit Resets" }
            return false
        }
    }

    private func countAndExpiries(_ line: MetricLine?) -> (Double?, [Date])? {
        guard case .values(_, let values, _, let expiries, _, _) = line else { return nil }
        return (values.first?.number, expiries)
    }

    private func date(_ text: String) -> Date { RunwayISO8601.date(from: text)! }

    // MARK: - Mapper

    func testMapsEachRemainingResetWithItsGrantDeadline() throws {
        // Shape as upstream OpenUsage recorded it (PR #1290), plus a second grant with two resets
        // left so both share one deadline, a spent grant, and a lapsed one.
        let line = try resetsLine("""
        { "cedar_ember": {
            "eligible": true, "at_limit": false, "exhausted": [],
            "grants": [
              { "id": "launch", "resets_total": 1, "resets_left": 1,
                "starts_at": "2026-09-22T16:00:00+00:00", "ends_at": "2026-10-22T16:00:00+00:00",
                "clears": ["five_hour", "seven_day"], "paused": false, "usable_now": true },
              { "id": "other", "resets_total": 2, "resets_left": 2, "ends_at": "2026-10-01T00:00:00+00:00" },
              { "id": "spent", "resets_total": 1, "resets_left": 0, "ends_at": "2026-10-05T00:00:00+00:00" },
              { "id": "lapsed", "resets_total": 1, "resets_left": 1, "ends_at": "2026-09-01T00:00:00+00:00" }
            ],
            "next_grant_id": "launch" } }
        """)

        let (count, expiries) = try XCTUnwrap(countAndExpiries(line))
        XCTAssertEqual(count, 3)
        XCTAssertEqual(expiries, [
            date("2026-10-01T00:00:00+00:00"),
            date("2026-10-01T00:00:00+00:00"),
            date("2026-10-22T16:00:00+00:00")
        ])
        guard case .values(_, let values, _, _, _, _) = line else { return XCTFail("expected values") }
        XCTAssertEqual(values, [MetricValue(number: 3, kind: .count, label: "available")])
    }

    func testGrantWithoutDeadlineCountsWithNoExpiry() throws {
        let line = try resetsLine(#"{"cedar_ember":{"eligible":true,"grants":[{"id":"g","resets_left":1,"ends_at":null}]}}"#)
        let (count, expiries) = try XCTUnwrap(countAndExpiries(line))
        XCTAssertEqual(count, 1)
        XCTAssertEqual(expiries, [])
    }

    func testExpiredGrantAndSpentGrantAreSkipped() throws {
        let line = try resetsLine("""
        {"cedar_ember":{"eligible":true,"grants":[
          {"id":"lapsed","resets_left":2,"ends_at":"2026-09-01T00:00:00+00:00"},
          {"id":"spent","resets_left":0,"ends_at":"2026-10-05T00:00:00+00:00"}
        ]}}
        """)
        let (count, expiries) = try XCTUnwrap(countAndExpiries(line))
        XCTAssertEqual(count, 0)
        XCTAssertEqual(expiries, [])
    }

    func testPausedGrantStillCounts() throws {
        let line = try resetsLine("""
        {"cedar_ember":{"eligible":true,"grants":[
          {"id":"g","resets_left":1,"ends_at":"2026-10-22T16:00:00+00:00","paused":true,"usable_now":false}
        ]}}
        """)
        let (count, expiries) = try XCTUnwrap(countAndExpiries(line))
        XCTAssertEqual(count, 1)
        XCTAssertEqual(expiries, [date("2026-10-22T16:00:00+00:00")])
    }

    func testIneligibleAccountReadsZeroAvailable() throws {
        let line = try resetsLine(#"{"cedar_ember":{"eligible":false,"ineligible_reason":"tier","grants":[{"id":"g","resets_left":1}]}}"#)
        let (count, expiries) = try XCTUnwrap(countAndExpiries(line))
        XCTAssertEqual(count, 0)
        XCTAssertEqual(expiries, [])
    }

    func testMissingOrNullBlockEmitsNoRow() throws {
        XCTAssertNil(try resetsLine(#"{"cedar_ember":null}"#))
        XCTAssertNil(try resetsLine(#"{"five_hour":{"utilization":3}}"#))
    }

    // MARK: - Request

    func testUsageRequestOptsInToResetGrantsAndIdentifiesAsClaudeCode() async throws {
        // Anthropic gates reset grants by client surface: upstream found the old `claude-code/2.1.69`
        // string comes back `eligible: false, ineligible_reason: "surface"` with no grants.
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8)))
        _ = try await ClaudeUsageClient(httpClient: http).fetchUsage(
            accessToken: "token",
            usageURL: URL(string: "https://api.anthropic.com/api/oauth/usage")!
        )

        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.url.absoluteString, "https://api.anthropic.com/api/oauth/usage?cedar_ember=1")
        XCTAssertEqual(request.headers["User-Agent"], "claude-cli/2.1.280 (external, cli)")
        XCTAssertEqual(request.headers["Authorization"], "Bearer token")
    }

    func testResetGrantFlagKeepsExistingQueryItems() {
        let url = ClaudeUsageClient.usageURLWithResetGrants(URL(string: "http://localhost:8000/api/oauth/usage?a=b")!)
        XCTAssertEqual(url.absoluteString, "http://localhost:8000/api/oauth/usage?a=b&cedar_ember=1")
    }

    // MARK: - Descriptor and layout

    func testDescriptorMatchesCodexAndSitsBetweenExtraUsageAndUsageTrend() throws {
        let claude = ClaudeProvider().widgetDescriptors
        let ids = claude.map(\.id)
        let index = try XCTUnwrap(ids.firstIndex(of: "claude.rateLimitResets"))
        XCTAssertEqual(ids[index - 1], "claude.extra")
        XCTAssertEqual(ids[index + 1], "claude.trend")

        let row = claude[index]
        let codex = try XCTUnwrap(CodexProvider().widgetDescriptors.first { $0.id == "codex.rateLimitResets" })
        XCTAssertEqual(row.title, "Rate Limit Resets")
        XCTAssertEqual(row.title, codex.title)
        XCTAssertEqual(row.metricLabel, codex.metricLabel)
        XCTAssertEqual(row.sample.showsResetExpiries, true)
        XCTAssertEqual(row.sample.traySuffix, codex.sample.traySuffix)
        XCTAssertEqual(row.sample.isUsagePeriod, false)
        XCTAssertEqual(row.limitResources, codex.limitResources)
    }

    func testDefaultLayoutMirrorsCodexForTheResetsRow() {
        for (name, list) in [
            ("metricIDs", DefaultLayout.metricIDs),
            ("expandedMetricIDs", DefaultLayout.expandedMetricIDs),
            ("pinnedMetricIDs", DefaultLayout.pinnedMetricIDs)
        ] {
            XCTAssertEqual(
                list.contains("claude.rateLimitResets"), list.contains("codex.rateLimitResets"),
                "\(name) must treat Claude's resets row like Codex's"
            )
        }
        XCTAssertTrue(DefaultLayout.metricIDs.contains("claude.rateLimitResets"))
        XCTAssertTrue(DefaultLayout.expandedMetricIDs.contains("claude.rateLimitResets"))
        XCTAssertFalse(DefaultLayout.pinnedMetricIDs.contains("claude.rateLimitResets"))
        // The baseline is a frozen snapshot of what pre-seeding installs had already been offered.
        // Listing the new row there would stop those installs from ever receiving it.
        XCTAssertFalse(DefaultLayout.migrationBaselineMetricIDs.contains("claude.rateLimitResets"))
    }

    func testExistingInstallReceivesTheRowEnabledBelowTheCaretInItsDeclaredSlot() throws {
        let defaults = try XCTUnwrap(UserDefaults(testSuiteName: "ClaudeResetGrantsTests.\(UUID().uuidString)"))
        // An install from before this row shipped: its saved layout, seed marker, caret split, pins,
        // and Customize order all predate `claude.rateLimitResets`.
        let persistence = LayoutPersistence(defaults: defaults, storageKey: "layout")
        let before = ["claude.session", "claude.weekly", "claude.fable", "claude.trend",
                      "claude.today", "claude.yesterday", "claude.last30"]
        persistence.savePlaced(before.map { PlacedWidget(descriptorID: $0) })
        persistence.saveSeededDefaults(Set(before))
        persistence.saveExpandedMetrics(["claude.today"])
        persistence.savePins(["claude.session"])
        persistence.saveMetricOrder(["claude": [
            "claude.weekly", "claude.session", "claude.sonnet", "claude.fable", "claude.extra",
            "claude.trend", "claude.today", "claude.yesterday", "claude.last30"
        ]])

        let store = LayoutStore(registry: .from([ClaudeProvider()]), defaults: defaults, storageKey: "layout")

        XCTAssertTrue(store.isMetricEnabled("claude.rateLimitResets"))
        XCTAssertEqual(store.expandedMetricIDs, ["claude.today", "claude.rateLimitResets"])
        XCTAssertFalse(store.isPinned("claude.rateLimitResets"))
        XCTAssertEqual(store.orderedSupportedMetrics(for: "claude").map(\.id), [
            "claude.weekly", "claude.session", "claude.sonnet", "claude.fable", "claude.extra",
            "claude.rateLimitResets", "claude.trend", "claude.today", "claude.yesterday", "claude.last30"
        ])

        // Offered once: turning it off survives the next launch.
        store.setMetricEnabled("claude.rateLimitResets", false)
        let relaunched = LayoutStore(registry: .from([ClaudeProvider()]), defaults: defaults, storageKey: "layout")
        XCTAssertFalse(relaunched.isMetricEnabled("claude.rateLimitResets"))
    }

    // MARK: - Popover

    func testPopoverEntriesStayDistinctWhenResetsShareADeadline() {
        let deadline = now.addingTimeInterval(10 * 86_400)
        let later = now.addingTimeInterval(20 * 86_400)
        let entries = RateLimitResetsDetail.entries(from: [later, deadline, deadline], now: now)
        XCTAssertEqual(entries.map(\.number), [1, 2, 3])
        XCTAssertEqual(entries.map(\.date), [deadline, deadline, later])
        XCTAssertEqual(Set(entries.map(\.key)).count, 3)
        XCTAssertEqual(entries.map(\.key.ordinal), [0, 1, 0])
    }

    func testClaudeCardsNeverResolveAClaimService() {
        // The popover only shows "Use" when a claim service is bound for the row's provider. The
        // router is keyed by Codex card ids and the environment default is nil, so a Claude row
        // (default card or an extra account card) always renders the read-only timeline.
        let codex = CodexProvider()
        let router = CodexResetClaimRouter(servicesByProviderID: [
            codex.provider.id: CodexResetClaimService(authStore: codex.authStore, usageClient: codex.usageClient, refreshAfterClaim: {})
        ])
        XCTAssertNotNil(router.service(for: "codex"))
        XCTAssertNil(router.service(for: ClaudeProvider().provider.id))
        XCTAssertNil(router.service(for: "claude@ab12cd34"))
        XCTAssertNil(EnvironmentValues().codexResetClaim)
    }

    // MARK: - Last-good usage

    func testRateLimitedLastGoodUsageKeepsTheRowButDropsGrantsPastTheirDeadline() async throws {
        let t0 = date("2026-09-21T12:00:00+00:00")
        let clock = ResetGrantClock(t0)
        let httpClient = RoutingHTTPClient { request in
            guard request.url.path.hasSuffix("/api/oauth/usage") else {
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
            guard clock.nextCall() == 1 else {
                return HTTPResponse(statusCode: 429, headers: ["retry-after": "7200"], body: Data())
            }
            return HTTPResponse(statusCode: 200, headers: [:], body: Data("""
            {"five_hour":{"utilization":25,"resets_at":"2099-01-01T00:00:00.000Z"},
             "cedar_ember":{"eligible":true,"grants":[
               {"id":"soon","resets_left":2,"ends_at":"2026-09-21T13:00:00+00:00"},
               {"id":"later","resets_left":1,"ends_at":"2026-10-22T16:00:00+00:00"},
               {"id":"open","resets_left":1,"ends_at":null}
             ]}}
            """.utf8))
        }
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
                files: FakeFiles([
                    "/tmp/claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"token","subscriptionType":"pro","scopes":["user:profile"]}}"#
                ]),
                keychain: FakeKeychain(),
                now: { clock.now }
            ),
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            now: { clock.now },
            pricing: { TestPricing.bundled }
        )
        let soon = date("2026-09-21T13:00:00+00:00")
        let later = date("2026-10-22T16:00:00+00:00")

        let first = await provider.refresh()
        let live = try XCTUnwrap(countAndExpiries(Self.resetsLine(in: first.lines)))
        XCTAssertEqual(live.0, 4)
        XCTAssertEqual(live.1, [soon, soon, later])

        // 429: the row rides along with the last-good usage, unchanged while every grant is live.
        let limited = await provider.refresh()
        XCTAssertEqual(limited.resolvedWarningAction, .wait)
        let carried = try XCTUnwrap(countAndExpiries(Self.resetsLine(in: limited.lines)))
        XCTAssertEqual(carried.0, 4)
        XCTAssertEqual(carried.1, [soon, soon, later])

        // Still inside the cooldown, but past the first grant's deadline: its two resets leave both
        // the count and the expiry list. The deadline-free reset and the later grant stay.
        clock.set(t0.addingTimeInterval(90 * 60))
        let third = await provider.refresh()
        let stale = try XCTUnwrap(countAndExpiries(Self.resetsLine(in: third.lines)))
        XCTAssertEqual(stale.0, 2)
        XCTAssertEqual(stale.1, [later])
        XCTAssertEqual(httpClient.requests.count, 2, "the cooldown must skip the live call")
    }
}

private final class ResetGrantClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var calls = 0

    init(_ date: Date) { current = date }

    var now: Date { lock.withLock { current } }
    func set(_ date: Date) { lock.withLock { current = date } }
    func nextCall() -> Int {
        lock.withLock {
            calls += 1
            return calls
        }
    }
}
