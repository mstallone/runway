import XCTest
@testable import Runway

/// Shared setup for the Claude launch-cache tests: each "launch" is a real `ClaudeProvider` behind a
/// real `WidgetDataStore` and snapshot cache over the same defaults, as `AppContainer` assembles them.
@MainActor
class ClaudeLaunchSnapshotTestCase: XCTestCase {
    func makeDefaults(_ name: String) -> UserDefaults {
        let suiteName = "ClaudeLaunchSnapshotTests.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(testSuiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    func makeFiles() -> FakeFiles {
        FakeFiles([
            ClaudeLaunchFixture.credentialsPath: ClaudeLaunchFixture.credentials(),
            ClaudeLaunchFixture.statePath: ClaudeLaunchFixture.stateFile()
        ])
    }

    /// What the previous session left on disk for the Claude card.
    func seedCache(
        _ defaults: UserDefaults,
        lines: [MetricLine] = [
            .progress(label: "Session", used: 25, limit: 100, format: .percent, resetsAt: ClaudeLaunchFixture.future),
            .progress(label: "Weekly", used: 40, limit: 100, format: .percent, resetsAt: ClaudeLaunchFixture.future)
        ],
        warning: String? = nil,
        refreshedAt: Date = ClaudeLaunchFixture.now.addingTimeInterval(-3600),
        stamp: String? = ClaudeLaunchFixture.identityKey
    ) {
        ProviderSnapshotCache(userDefaults: defaults).store(
            ProviderSnapshot(
                providerID: "claude",
                displayName: "Claude",
                plan: "Pro",
                lines: lines,
                refreshedAt: refreshedAt,
                warning: warning
            ),
            producedByIdentityKey: stamp
        )
    }

    /// One app launch: a fresh provider (no in-memory last-good usage), a fresh cache instance over
    /// the same defaults, and a store that paints from it — exactly what `AppContainer` assembles.
    func launch(
        defaults: UserDefaults,
        files: FakeFiles,
        keychain: KeychainReading = FakeKeychain(),
        http: HTTPClient,
        identityKeys: [String: String] = ["claude": ClaudeLaunchFixture.identityKey],
        logHome: URL? = nil,
        clock: ClaudeLaunchClock = ClaudeLaunchClock(ClaudeLaunchFixture.now),
        oneShotCLI: Bool = false
    ) -> WidgetDataStore {
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
                files: files,
                keychain: keychain,
                now: { clock.now }
            ),
            usageClient: ClaudeUsageClient(httpClient: http),
            logUsageScanner: ClaudeLogFixture.scanner(home: logHome),
            now: { clock.now },
            pricing: { TestPricing.bundled }
        )
        return WidgetDataStore(
            registry: WidgetRegistry.from([provider]),
            providers: [provider],
            // The one-shot `runway` command builds its cache exactly like this (see `UsageReader`).
            cache: ProviderSnapshotCache(
                userDefaults: defaults, allowsPersistedFreshness: oneShotCLI, now: { clock.now }
            ),
            defaults: defaults,
            now: { clock.now },
            providerIdentityKeys: identityKeys
        )
    }

    func used(_ snapshot: ProviderSnapshot?, _ label: String) -> Double? {
        guard case .progress(_, let used, _, _, _, _, _)? = snapshot?.line(label: label) else { return nil }
        return used
    }

    func badgeText(_ snapshot: ProviderSnapshot?, _ label: String) -> String? {
        guard case .badge(_, let text, _, _)? = snapshot?.line(label: label) else { return nil }
        return text
    }

    func values(_ snapshot: ProviderSnapshot?, _ label: String) -> [MetricValue]? {
        guard case .values(_, let values, _, _, _, _)? = snapshot?.line(label: label) else { return nil }
        return values
    }

    func assertBareBadge(_ snapshot: ProviderSnapshot?, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(badgeText(snapshot, "Status")?.hasPrefix("Rate limited"), true, file: file, line: line)
        XCTAssertNil(snapshot?.line(label: "Session"), file: file, line: line)
        XCTAssertNil(snapshot?.line(label: "Weekly"), file: file, line: line)
        XCTAssertEqual(snapshot?.warning?.hasPrefix("Updates blocked by Anthropic"), true, file: file, line: line)
    }
}

/// Fixture values, outside the main-actor test class so the fakes' `@Sendable` closures can read them.
enum ClaudeLaunchFixture {
    static let now = RunwayISO8601.date(from: "2026-02-20T16:00:00.000Z")!
    static let future = RunwayISO8601.date(from: "2099-01-01T00:00:00.000Z")!
    static let identityKey = "acct-a|org-1"
    static let credentialsPath = "/tmp/claude/.credentials.json"
    static let statePath = "/tmp/claude/.claude.json"
    static let rateLimited = HTTPResponse(statusCode: 429, headers: ["retry-after": "600"], body: Data())

    static func credentials(accessToken: String = "token") -> String {
        #"{"claudeAiOauth":{"accessToken":"\#(accessToken)","refreshToken":"refresh-\#(accessToken)","subscriptionType":"pro","scopes":["user:profile"]}}"#
    }

    static func stateFile(account: String = "ACCT-A") -> String {
        #"{"oauthAccount":{"accountUuid":"\#(account)","organizationUuid":"ORG-1"}}"#
    }

    static func usage(session: Double) -> HTTPResponse {
        HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data(#"{"five_hour":{"utilization":\#(session),"resets_at":"2099-01-01T00:00:00.000Z"}}"#.utf8)
        )
    }
}

final class ClaudeLaunchClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func set(_ value: Date) {
        lock.lock(); defer { lock.unlock() }
        self.value = value
    }
}

final class ClaudeLaunchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}
