import XCTest
@testable import Runway

private let museNow = Date(timeIntervalSince1970: 1_800_000_000)
private let museDefaultAuthPath = MuseAuthStore.defaultAuthPath

// MARK: - Auth

final class MuseAuthStoreTests: XCTestCase {
    func testLoadsKeychainAccessToken() {
        let store = MuseAuthStore(
            keychain: museAccountKeychain(),
            files: FakeFiles(),
            environment: FakeEnvironment()
        )

        let auth = store.loadCredentials().token

        XCTAssertEqual(auth?.accessToken, "oauth-access")
    }

    func testKeychainWinsOverLegacyAuthFile() {
        let store = MuseAuthStore(
            keychain: museAccountKeychain(token: "from-keychain"),
            files: FakeFiles([museDefaultAuthPath: #"{"access_token":"from-file"}"#]),
            environment: FakeEnvironment()
        )

        XCTAssertEqual(store.loadCredentials().token?.accessToken, "from-keychain")
    }

    func testLoadsLegacyAuthFileWhenKeychainIsEmpty() {
        let store = MuseAuthStore(
            keychain: AccountKeychain(),
            files: FakeFiles([museDefaultAuthPath: #"{"access_token":"from-file"}"#]),
            environment: FakeEnvironment()
        )

        XCTAssertEqual(store.loadCredentials().token?.accessToken, "from-file")
    }

    func testHonorsMuseAuthPath() {
        let path = "/tmp/muse-work/auth.json"
        let store = MuseAuthStore(
            keychain: AccountKeychain(),
            files: FakeFiles([path: #"{"access_token":"override-token"}"#]),
            environment: FakeEnvironment(["MUSE_AUTH_PATH": path])
        )

        XCTAssertEqual(store.authFilePath(), path)
        XCTAssertEqual(store.loadCredentials().token?.accessToken, "override-token")
    }

    func testHonorsXDGConfigHome() {
        let path = "/tmp/xdg-config/muse/auth.json"
        let store = MuseAuthStore(
            keychain: AccountKeychain(),
            files: FakeFiles([path: #"{"providers":{"meta":{"access_token":"xdg-token"}}}"#]),
            environment: FakeEnvironment(["XDG_CONFIG_HOME": "/tmp/xdg-config/"])
        )

        XCTAssertEqual(store.authFilePath(), path)
        XCTAssertEqual(store.loadCredentials().token?.accessToken, "xdg-token")
    }

    func testSchemaV2PointerFileIsNotALogin() {
        let store = MuseAuthStore(
            keychain: AccountKeychain(),
            files: FakeFiles([museDefaultAuthPath: #"""
            {
              "schema_version": 2,
              "providers": {
                "meta": {
                  "mechanism": "oauth",
                  "storage": "keychain"
                }
              }
            }
            """#]),
            environment: FakeEnvironment()
        )

        XCTAssertEqual(store.loadCredentials(), .none)
        XCTAssertFalse(store.hasCredentialFootprint())
    }

    func testMetaAPIKeyIsNotASubscriptionLogin() {
        let store = MuseAuthStore(
            keychain: AccountKeychain(),
            files: FakeFiles(),
            environment: FakeEnvironment(["META_API_KEY": "LLM|not-a-login"])
        )

        XCTAssertEqual(store.loadCredentials(), .none)
        XCTAssertFalse(store.hasCredentialFootprint())
    }

    func testProtectedKeychainItemIsAConnectPromptAndCountsAsCredentials() {
        let store = MuseAuthStore(
            keychain: museAccountKeychain(requiresInteractiveRead: true),
            files: FakeFiles(),
            environment: FakeEnvironment()
        )

        XCTAssertEqual(store.loadCredentials(), .connectRequired)
        XCTAssertTrue(store.hasCredentialFootprint())
        XCTAssertEqual(
            store.loadCredentials(allowKeychainInteraction: true).token?.accessToken,
            "oauth-access"
        )
    }

    func testMalformedKeychainItemIsInvalid() {
        let store = MuseAuthStore(
            keychain: AccountKeychain(accountValues: [
                AccountKeychain.key(
                    service: MuseAuthStore.keychainService,
                    account: MuseAuthStore.keychainAccount
                ): #"{"api_key":"LLM|only-a-key"}"#
            ]),
            files: FakeFiles(),
            environment: FakeEnvironment()
        )

        XCTAssertEqual(store.loadCredentials(), .invalid)
        XCTAssertTrue(store.hasCredentialFootprint())
    }

    func testParseAuthFileAcceptsNestedAndRootTokens() {
        XCTAssertEqual(
            MuseAuthStore.parseAuthFile(#"{"access_token":"root"}"#),
            .token("root")
        )
        XCTAssertEqual(
            MuseAuthStore.parseAuthFile(#"{"providers":{"meta":{"access_token":"nested"}}}"#),
            .token("nested")
        )
        XCTAssertEqual(MuseAuthStore.parseAuthFile("{"), .malformed)
        XCTAssertEqual(MuseAuthStore.parseAuthFile(#"{"schema_version":2}"#), .pointerOnly)
    }
}

// MARK: - Mapper

final class MuseUsageMapperTests: XCTestCase {
    func testMapsWindowsPlanAndUnixResets() throws {
        let mapped = try MuseUsageMapper.map(Data(museKeyJSON().utf8))

        XCTAssertEqual(mapped.plan, "Power Usage")
        XCTAssertEqual(mapped.lines.map(\.label), ["Five-Hour Usage", "Weekly Usage"])

        let session = try XCTUnwrap(museProgress(mapped.lines, "Five-Hour Usage"))
        XCTAssertEqual(session.used, 12)
        XCTAssertEqual(session.limit, 100)
        XCTAssertEqual(session.format, .percent)
        XCTAssertEqual(session.resetsAt, Date(timeIntervalSince1970: 1_788_585_458))
        XCTAssertEqual(session.periodDurationMs, MetricPeriod.sessionMs)

        let weekly = try XCTUnwrap(museProgress(mapped.lines, "Weekly Usage"))
        XCTAssertEqual(weekly.used, 34)
        XCTAssertEqual(weekly.resetsAt, Date(timeIntervalSince1970: 1_788_739_200))
        XCTAssertEqual(weekly.periodDurationMs, MetricPeriod.weekMs)
    }

    func testZeroPercentIsValidAndClampsOverfill() throws {
        let zero = try MuseUsageMapper.map(Data(museKeyJSON(windowPercent: 0, weeklyPercent: 0).utf8))
        XCTAssertEqual(try XCTUnwrap(museProgress(zero.lines, "Five-Hour Usage")).used, 0)

        let over = try MuseUsageMapper.map(Data(museKeyJSON(windowPercent: 140, weeklyPercent: -5).utf8))
        XCTAssertEqual(try XCTUnwrap(museProgress(over.lines, "Five-Hour Usage")).used, 100)
        XCTAssertEqual(try XCTUnwrap(museProgress(over.lines, "Weekly Usage")).used, 0)
    }

    func testCustomWindowDurationUsesReportedMinutes() throws {
        let mapped = try MuseUsageMapper.map(Data(museKeyJSON(windowDurationMins: 90).utf8))
        XCTAssertEqual(
            try XCTUnwrap(museProgress(mapped.lines, "Five-Hour Usage")).periodDurationMs,
            90 * 60 * 1000
        )
    }

    func testInactiveSubscriptionThrowsWithoutInventingMeters() {
        XCTAssertThrowsError(
            try MuseUsageMapper.map(Data(museKeyJSON(isActive: false, windowPercent: 40).utf8))
        ) { error in
            XCTAssertEqual(error as? MuseUsageError, .noSubscription)
        }
    }

    func testMissingUsageThrows() {
        XCTAssertThrowsError(try MuseUsageMapper.map(Data(#"{"is_subs_active":true}"#.utf8))) { error in
            XCTAssertEqual(error as? MuseUsageError, .invalidResponse)
        }
        XCTAssertThrowsError(try MuseUsageMapper.map(Data("{}".utf8))) { error in
            XCTAssertEqual(error as? MuseUsageError, .invalidResponse)
        }
    }

    func testMissingSubscriptionFlagIsInvalidEvenWhenUsageIsPresent() {
        let body = #"""
        {
          "subs_tier_name": "Muse Code Power Usage",
          "subs_usage": {
            "window": { "used_percent": 12, "window_duration_mins": 300, "resets_at": 1788585458 },
            "weekly": { "used_percent": 34, "resets_at": 1788739200 }
          }
        }
        """#
        XCTAssertThrowsError(try MuseUsageMapper.map(Data(body.utf8))) { error in
            XCTAssertEqual(error as? MuseUsageError, .invalidResponse)
        }
    }

    func testGatewayErrorEnvelopeIsRequestFailedNotInvalidResponse() {
        XCTAssertThrowsError(try MuseUsageMapper.map(Data(museGatewayJSON(status: 429).utf8))) { error in
            XCTAssertEqual(error as? MuseUsageError, .requestFailed(429))
        }
        XCTAssertEqual(
            MuseUsageMapper.effectiveStatus(of: museJSONResponse(museGatewayJSON(status: 429))),
            429
        )
        XCTAssertEqual(
            MuseUsageMapper.effectiveStatus(of: museJSONResponse(museGatewayJSON(status: 401))),
            401
        )
    }

    func testWrappedDataPayloadStillMaps() throws {
        let wrapped = #"{"data":\#(museKeyJSON())}"#
        let mapped = try MuseUsageMapper.map(Data(wrapped.utf8))
        XCTAssertEqual(mapped.plan, "Power Usage")
        XCTAssertEqual(mapped.lines.map(\.label), ["Five-Hour Usage", "Weekly Usage"])
    }

    func testDisplayPlanStripsMuseCodePrefix() {
        XCTAssertEqual(MuseUsageMapper.displayPlan("Muse Code Power Usage"), "Power Usage")
        XCTAssertEqual(MuseUsageMapper.displayPlan("High Usage"), "High Usage")
        XCTAssertNil(MuseUsageMapper.displayPlan("  "))
    }
}

// MARK: - Runtime

@MainActor
final class MuseProviderTests: XCTestCase {
    func testRefreshPostsKeyEndpointWithBearerToken() async {
        let http = RoutingHTTPClient { request in
            XCTAssertEqual(request.method, "POST")
            XCTAssertEqual(request.url, MuseUsageClient.keyURL)
            XCTAssertEqual(request.headers["Authorization"], "Bearer oauth-access")
            XCTAssertEqual(request.headers["Accept"], "application/json")
            XCTAssertEqual(request.headers["Content-Type"], "application/json")
            XCTAssertEqual(request.headers["User-Agent"], "Runway")
            XCTAssertEqual(request.headers["x-api-version"], "1.0.0")
            XCTAssertEqual(request.headers["x-client-id"], MuseUsageClient.clientSurface)
            XCTAssertEqual(String(decoding: request.body ?? Data(), as: UTF8.self), "{}")
            return museJSONResponse(museKeyJSON())
        }
        let provider = makeMuseProvider(http: http)

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.plan, "Power Usage")
        XCTAssertNotNil(snapshot.line(label: "Five-Hour Usage"))
        XCTAssertNotNil(snapshot.line(label: "Weekly Usage"))
        XCTAssertEqual(http.requests.count, 1)
    }

    func testLocalLogsAppendSpendTilesAndSurviveConnectPrompt() async throws {
        let scanner = try museLogScanner(tokens: 1_000_000)
        let http = RoutingHTTPClient { _ in museJSONResponse(museKeyJSON()) }
        let provider = makeMuseProvider(http: http, logUsageScanner: scanner)

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.plan, "Power Usage")
        XCTAssertNotNil(snapshot.line(label: "Five-Hour Usage"))
        XCTAssertNotNil(snapshot.line(label: "Weekly Usage"))
        XCTAssertNotNil(snapshot.line(label: "Today"))
        XCTAssertNotNil(snapshot.line(label: "Usage Trend"))
        XCTAssertEqual(snapshot.usageHistory?.series.daily.first?.totalTokens, 1_000_000)

        let connectProvider = makeMuseProvider(
            http: http,
            keychain: museAccountKeychain(requiresInteractiveRead: true),
            logUsageScanner: scanner
        )
        let connectSnapshot = await connectProvider.refresh()
        XCTAssertNil(connectSnapshot.line(label: "Five-Hour Usage"))
        XCTAssertNotNil(connectSnapshot.line(label: "Today"))
        XCTAssertEqual(connectSnapshot.warningIsConnectPrompt, true)
        XCTAssertEqual(http.requests.count, 1)
    }

    func testLogsAloneEnableTheProviderAndShowSpendWithoutALogin() async throws {
        let scanner = try museLogScanner(tokens: 500_000)
        let http = RoutingHTTPClient { _ in
            XCTFail("logs-only refresh must not call the network")
            return museJSONResponse("{}")
        }
        let provider = makeMuseProvider(
            http: http,
            keychain: AccountKeychain(),
            files: FakeFiles(),
            logUsageScanner: scanner
        )

        let hasCredentials = await provider.hasLocalCredentials()
        let snapshot = await provider.refresh()
        XCTAssertTrue(hasCredentials)
        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertNotNil(snapshot.line(label: "Today"))
        XCTAssertEqual(
            snapshot.warning,
            "Subscription meters unavailable: \(MuseAuthError.notLoggedIn.errorDescription ?? "")"
        )
    }

    func testUnauthorizedBecomesSessionExpired() async {
        let http = RoutingHTTPClient { _ in museJSONResponse("{}", status: 401) }
        let provider = makeMuseProvider(http: http)

        let snapshot = await provider.refresh()

        XCTAssertTrue(snapshot.lines.contains(where: \.isError))
        XCTAssertEqual(snapshot.line(label: MetricLine.errorBadgeLabel)?.label, MetricLine.errorBadgeLabel)
        XCTAssertEqual(
            snapshot.lines.first { $0.isError }.map { line -> String? in
                if case .badge(_, let text, _, _) = line { return text }
                return nil
            } ?? nil,
            MuseAuthError.sessionExpired.errorDescription
        )
    }

    func testHTTP200AuthEnvelopeBecomesSessionExpired() async {
        let http = RoutingHTTPClient { _ in museJSONResponse(museGatewayJSON(status: 401)) }
        let provider = makeMuseProvider(http: http)

        let snapshot = await provider.refresh()

        XCTAssertEqual(museErrorText(snapshot), MuseAuthError.sessionExpired.errorDescription)
        XCTAssertEqual(http.requests.count, 1)
    }

    func testRotatedAccessTokenIsRetriedOnce() async {
        let keychain = museAccountKeychain(token: "first")
        let http = RoutingHTTPClient { request in
            XCTAssertEqual(request.headers["x-client-id"], MuseUsageClient.clientSurface)
            if request.headers["Authorization"] == "Bearer first" {
                keychain.accountValues[
                    AccountKeychain.key(
                        service: MuseAuthStore.keychainService,
                        account: MuseAuthStore.keychainAccount
                    )
                ] = museKeychainJSON("second")
                return museJSONResponse(museGatewayJSON(status: 401))
            }
            XCTAssertEqual(request.headers["Authorization"], "Bearer second")
            return museJSONResponse(museKeyJSON())
        }
        let provider = makeMuseProvider(http: http, keychain: keychain)

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.plan, "Power Usage")
        XCTAssertEqual(http.requests.count, 2)
    }

    func testRateLimitServesLastGoodAndSkipsLaterMint() async {
        let probe = MuseRefreshProbe()
        let http = RoutingHTTPClient { _ in
            if probe.remainingSuccesses > 0 {
                probe.remainingSuccesses -= 1
                return museJSONResponse(museKeyJSON())
            }
            return museJSONResponse(museGatewayJSON(status: 429))
        }
        let provider = makeMuseProvider(http: http, now: { probe.now })

        let fresh = await provider.refresh()
        XCTAssertEqual(fresh.plan, "Power Usage")
        XCTAssertNil(fresh.warning)

        probe.now = museNow.addingTimeInterval(1)
        let limited = await provider.refresh()
        XCTAssertEqual(limited.plan, "Power Usage")
        XCTAssertEqual(limited.lines.map(\.label), fresh.lines.map(\.label))
        XCTAssertEqual(limited.warningAction, .wait)
        XCTAssertTrue(limited.warning?.contains("manual refreshes will make it worse") == true)
        XCTAssertEqual(http.requests.count, 2)

        probe.now = museNow.addingTimeInterval(60)
        let skipped = await provider.refresh()
        XCTAssertEqual(skipped.warningAction, .wait)
        XCTAssertEqual(http.requests.count, 2, "cooldown must not mint again")
    }

    func testRateLimitDoesNotServeLastGoodAfterLogout() async {
        let probe = MuseRefreshProbe()
        let keychain = museAccountKeychain()
        let http = RoutingHTTPClient { _ in
            if probe.remainingSuccesses > 0 {
                probe.remainingSuccesses -= 1
                return museJSONResponse(museKeyJSON())
            }
            return museJSONResponse(museGatewayJSON(status: 429))
        }
        let provider = makeMuseProvider(http: http, keychain: keychain, now: { probe.now })

        _ = await provider.refresh()
        probe.now = museNow.addingTimeInterval(1)
        _ = await provider.refresh()

        keychain.accountValues.removeAll()
        probe.now = museNow.addingTimeInterval(2)
        let loggedOut = await provider.refresh()

        XCTAssertEqual(museErrorText(loggedOut), MuseAuthError.notLoggedIn.errorDescription)
        XCTAssertEqual(http.requests.count, 2)
    }

    func testRateLimitDoesNotServeLastGoodAfterTokenChange() async {
        let probe = MuseRefreshProbe()
        let keychain = museAccountKeychain(token: "first")
        let http = RoutingHTTPClient { _ in
            if probe.remainingSuccesses > 0 {
                probe.remainingSuccesses -= 1
                return museJSONResponse(museKeyJSON())
            }
            return museJSONResponse(museGatewayJSON(status: 429))
        }
        let provider = makeMuseProvider(http: http, keychain: keychain, now: { probe.now })

        _ = await provider.refresh()
        probe.now = museNow.addingTimeInterval(1)
        _ = await provider.refresh()
        XCTAssertEqual(http.requests.count, 2)

        probe.remainingSuccesses = 1
        keychain.accountValues[
            AccountKeychain.key(
                service: MuseAuthStore.keychainService,
                account: MuseAuthStore.keychainAccount
            )
        ] = museKeychainJSON("second")
        probe.now = museNow.addingTimeInterval(2)
        let switched = await provider.refresh()

        XCTAssertEqual(switched.plan, "Power Usage")
        XCTAssertNil(switched.warning)
        XCTAssertEqual(http.requests.count, 3)
    }

    func testInactivePlanBecomesNoSubscription() async {
        let http = RoutingHTTPClient { _ in museJSONResponse(museKeyJSON(isActive: false)) }
        let provider = makeMuseProvider(http: http)

        let snapshot = await provider.refresh()

        XCTAssertEqual(
            museErrorText(snapshot),
            MuseUsageError.noSubscription.errorDescription
        )
    }

    func testAutomaticRefreshConnectsInsteadOfPrompting() async {
        let http = RoutingHTTPClient { _ in
            XCTFail("connect-required must not call the network")
            return museJSONResponse("{}")
        }
        let provider = makeMuseProvider(
            http: http,
            keychain: museAccountKeychain(requiresInteractiveRead: true)
        )

        let snapshot = await provider.refresh()

        XCTAssertTrue(snapshot.lines.contains(where: \.isConnectPrompt))
        XCTAssertTrue(http.requests.isEmpty)
        let hasCredentials = await provider.hasLocalCredentials()
        XCTAssertTrue(hasCredentials)
    }

    func testManualRefreshLoadsProtectedKeychainItem() async {
        let http = RoutingHTTPClient { _ in museJSONResponse(museKeyJSON()) }
        let provider = makeMuseProvider(
            http: http,
            keychain: museAccountKeychain(requiresInteractiveRead: true)
        )

        let snapshot = await ProviderRefreshContext.$isManual.withValue(true) {
            await provider.refresh()
        }

        XCTAssertEqual(snapshot.plan, "Power Usage")
        XCTAssertEqual(http.requests.count, 1)
    }

    func testMissingCredentialsAreDetectedWithoutNetwork() async {
        let http = RoutingHTTPClient { _ in
            XCTFail("missing credentials must not call the network")
            return museJSONResponse("{}")
        }
        let provider = makeMuseProvider(http: http, keychain: AccountKeychain(), files: FakeFiles())

        let hasCredentials = await provider.hasLocalCredentials()
        let snapshot = await provider.refresh()
        XCTAssertFalse(hasCredentials)
        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertEqual(museErrorText(snapshot), MuseAuthError.notLoggedIn.errorDescription)
    }

    func testConnectionFailureIsSurfaced() async {
        let http = RoutingHTTPClient { _ in throw URLError(.notConnectedToInternet) }
        let provider = makeMuseProvider(http: http)
        let snapshot = await provider.refresh()

        XCTAssertEqual(
            museErrorText(snapshot),
            MuseUsageError.connectionFailed.errorDescription
        )
    }

    func testDescriptorsAndCatalogOrderAreStable() throws {
        let provider = MuseProvider()
        XCTAssertEqual(
            provider.widgetDescriptors.map(\.id),
            [
                "muse.session", "muse.weekly", "muse.trend",
                "muse.today", "muse.yesterday", "muse.last30"
            ]
        )
        XCTAssertEqual(
            provider.widgetDescriptors.flatMap(\.limitResources).map(\.key),
            ["session", "weekly"]
        )
        XCTAssertTrue(provider.widgetDescriptors[0].sample.isSessionWindow)

        let ids = ProviderCatalog.make(
            defaults: UserDefaults(suiteName: "MuseProviderTests.\(UUID().uuidString)")!
        ).map(\.provider.id)
        let kimi = try XCTUnwrap(ids.firstIndex(of: "kimi"))
        let muse = try XCTUnwrap(ids.firstIndex(of: "muse"))
        let openCode = try XCTUnwrap(ids.firstIndex(of: "opencode"))
        XCTAssertEqual(muse, kimi + 1)
        XCTAssertEqual(openCode, muse + 1)
    }
}

@MainActor
final class MuseLayoutTests: XCTestCase {
    func testFreshDefaultsSeedApprovedMuseLayout() {
        let suiteName = "RunwayTests.MuseLayout.FreshDefaults.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = LayoutStore(
            registry: .from([MuseProvider()]),
            defaults: defaults,
            storageKey: "layout"
        )

        XCTAssertEqual(store.placed.map(\.descriptorID), [
            "muse.session",
            "muse.weekly",
            "muse.trend",
            "muse.today",
            "muse.yesterday",
            "muse.last30"
        ])
        XCTAssertEqual(Set(store.pinnedMetricIDs), ["muse.session", "muse.weekly"])

        let group = store.customizeGroups.first { $0.provider.id == "muse" }
        XCTAssertEqual(group?.alwaysShownMetrics.map(\.id), ["muse.session", "muse.weekly"])
        XCTAssertEqual(group?.expandedMetrics.map(\.id), [
            "muse.trend",
            "muse.today",
            "muse.yesterday",
            "muse.last30"
        ])
    }

    func testExistingLayoutKeepsMetersAlwaysShownWhenSpendTilesSeed() {
        let suiteName = "RunwayTests.MuseLayout.ExistingSpendSeed.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(
            try! JSONEncoder().encode([
                PlacedWidget(descriptorID: "muse.session"),
                PlacedWidget(descriptorID: "muse.weekly")
            ]),
            forKey: "layout"
        )
        defaults.set(
            try! JSONEncoder().encode(["muse.session", "muse.weekly"]),
            forKey: "layout.seededDefaults"
        )
        defaults.set([] as [String], forKey: "layout.expandedMetrics")
        defaults.set(["muse.session", "muse.weekly"], forKey: "layout.menuBarPins")

        let store = LayoutStore(
            registry: .from([MuseProvider()]),
            defaults: defaults,
            storageKey: "layout"
        )

        XCTAssertFalse(store.expandedMetricIDs.contains("muse.session"))
        XCTAssertFalse(store.expandedMetricIDs.contains("muse.weekly"))
        XCTAssertTrue(store.expandedMetricIDs.contains("muse.trend"))
        XCTAssertTrue(store.expandedMetricIDs.contains("muse.today"))
        XCTAssertEqual(Set(store.pinnedMetricIDs), ["muse.session", "muse.weekly"])
    }
}

@MainActor
private func makeMuseProvider(
    http: RoutingHTTPClient,
    keychain: KeychainReading = museAccountKeychain(),
    files: FakeFiles = FakeFiles(),
    logUsageScanner: MuseLogUsageScanner? = nil,
    now: @escaping @Sendable () -> Date = { museNow }
) -> MuseProvider {
    MuseProvider(
        authStore: MuseAuthStore(
            keychain: keychain,
            files: files,
            environment: FakeEnvironment()
        ),
        usageClient: MuseUsageClient(http: http),
        logUsageScanner: logUsageScanner ?? MuseLogUsageScanner(
            environment: FakeEnvironment(["XDG_DATA_HOME": "/tmp/runway-muse-empty"]),
            homeDirectory: { URL(fileURLWithPath: "/home/none") },
            incrementalScanner: IncrementalJSONLScanner<MuseLogUsageScanner.Entry>()
        ),
        now: now,
        pricing: { TestPricing.bundled }
    )
}

@MainActor
private func museLogScanner(tokens: Int) throws -> MuseLogUsageScanner {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("runway-muse-provider-\(UUID().uuidString)", isDirectory: true)
    let recordedAt = Int(museNow.timeIntervalSince1970 * 1_000_000)
    let line = museCompletedLine(
        recordedAt: recordedAt,
        model: "muse-spark-1.3",
        input: tokens,
        output: 0
    )
    let sessionDir = root.appendingPathComponent("muse/sessions/2026/08/22/session-a", isDirectory: true)
    try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
    let file = sessionDir.appendingPathComponent("session.jsonl")
    try (line + "\n").write(to: file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: museNow], ofItemAtPath: file.path)
    return MuseLogUsageScanner(
        environment: FakeEnvironment(["XDG_DATA_HOME": root.path]),
        homeDirectory: { URL(fileURLWithPath: "/home/ignored") },
        incrementalScanner: IncrementalJSONLScanner<MuseLogUsageScanner.Entry>()
    )
}

private func museAccountKeychain(
    token: String = "oauth-access",
    requiresInteractiveRead: Bool = false
) -> AccountKeychain {
    AccountKeychain(
        accountValues: [
            AccountKeychain.key(
                service: MuseAuthStore.keychainService,
                account: MuseAuthStore.keychainAccount
            ): museKeychainJSON(token)
        ],
        requiresInteractiveRead: requiresInteractiveRead
    )
}

private func museKeychainJSON(_ accessToken: String) -> String {
    #"{"secret_schema_version":1,"access_token":"\#(accessToken)"}"#
}

private func museKeyJSON(
    isActive: Bool = true,
    windowPercent: Double = 12,
    weeklyPercent: Double = 34,
    windowDurationMins: Int = 300
) -> String {
    #"""
    {
      "is_subs_active": \#(isActive),
      "subs_tier_name": "Muse Code Power Usage",
      "subs_usage": {
        "window": {
          "used_percent": \#(windowPercent),
          "window_duration_mins": \#(windowDurationMins),
          "resets_at": 1788585458
        },
        "weekly": {
          "used_percent": \#(weeklyPercent),
          "resets_at": 1788739200
        }
      }
    }
    """#
}

private func museJSONResponse(_ body: String, status: Int = 200) -> HTTPResponse {
    HTTPResponse(statusCode: status, headers: [:], body: Data(body.utf8))
}

private func museGatewayJSON(status: Int, title: String = "Too Many Requests") -> String {
    #"""
    {"title":"\#(title)","detail":"Wait a bit and try again.","status":\#(status)}
    """#
}

private struct MuseProgressFields {
    var used: Double
    var limit: Double
    var format: ProgressFormat
    var resetsAt: Date?
    var periodDurationMs: Int?
}

private func museProgress(_ lines: [MetricLine], _ label: String) -> MuseProgressFields? {
    guard let line = lines.first(where: { $0.label == label }),
          case .progress(_, let used, let limit, let format, let resetsAt, let periodDurationMs, _) = line
    else {
        return nil
    }
    return MuseProgressFields(
        used: used,
        limit: limit,
        format: format,
        resetsAt: resetsAt,
        periodDurationMs: periodDurationMs
    )
}

private func museErrorText(_ snapshot: ProviderSnapshot) -> String? {
    snapshot.lines.compactMap { line -> String? in
        guard case .badge(let label, let text, _, _) = line, label == MetricLine.errorBadgeLabel else {
            return nil
        }
        return text
    }.first
}

private final class MuseRefreshProbe: @unchecked Sendable {
    var now = museNow
    var remainingSuccesses = 1
}
