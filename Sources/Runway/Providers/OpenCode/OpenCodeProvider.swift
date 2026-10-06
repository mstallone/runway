import Foundation

/// Typed failures for the OpenCode provider, preserving friendly user-facing descriptions.
enum OpenCodeUsageError: Error, LocalizedError, Equatable {
    case notLoggedIn
    /// `auth.json` exists but could not be read or parsed — broken storage, not logout. `detail` carries the underlying cause for the log
    /// file and never a credential value; the user-facing description stays friendly.
    case credentialsUnreadable(detail: String)
    /// A database that holds (or decides) the login could not be queried, or its credential row is
    /// malformed. Unlike a bad `auth.json` this is usually a busy or locked database. `detail` is
    /// sqlite3's message for the log file, never a credential value.
    case credentialDatabaseUnreadable(detail: String)
    /// OpenCode databases exist on disk but none could be read this refresh. Failing loudly here beats
    /// rendering authoritative-looking $0 tiles from an empty scan.
    case databaseUnreadable
    case connectionFailed
    case invalidResponse
    case requestFailed(Int)
    /// The local Go key was rejected (HTTP 401 / `AuthError`).
    case unauthorized
    /// Valid key, but this account has no Go subscription (HTTP 403 / `EntitlementError`).
    case noGoSubscription

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "OpenCode not detected. Log in with OpenCode Go or use OpenCode locally first."
        case .credentialsUnreadable:
            return "Couldn't read OpenCode's saved login. Quit OpenCode and refresh, or log into OpenCode Go again."
        case .databaseUnreadable, .credentialDatabaseUnreadable:
            return "Couldn't read OpenCode's local database. Quit OpenCode and refresh, or check the data directory's permissions."
        case .connectionFailed:
            return ProviderUsageErrorText.connectionFailed
        case .invalidResponse:
            return ProviderUsageErrorText.invalidResponse
        case .requestFailed(let status):
            return ProviderUsageErrorText.requestFailed(statusCode: status)
        case .unauthorized:
            return "OpenCode Go key was rejected. Log into OpenCode Go again."
        case .noGoSubscription:
            return "No OpenCode Go subscription on this key."
        }
    }
}

/// Tracks OpenCode-hosted usage: Go plan windows from the official usage API, plus local spend tiles
/// and a usage trend from OpenCode's SQLite logs (Go + Zen).
@MainActor
final class OpenCodeProvider: ProviderRuntime {
    let provider = Provider(
        id: "opencode",
        displayName: "OpenCode",
        icon: .providerMark("opencode"),
        links: [
            .init(label: "Dashboard", url: "https://opencode.ai/auth")
        ]
    )

    let authStore: OpenCodeAuthStore
    let usageClient: OpenCodeUsageClient
    let usageScanner: OpenCodeUsageScanner
    let now: @Sendable () -> Date

    /// Names the local source on hover (the dollars can only undercount true account usage — this
    /// machine only). No "(estimated)": OpenCode records its own per-message cost, so the values are
    /// measured, not imputed.
    private let sourceNote = "From your OpenCode logs"

    /// Edge-triggers the auth-read-failure log so a persistently unreadable credential store warns
    /// once per run, not once per 5-minute refresh.
    private var loggedAuthReadFailure = false

    /// Whether a Go key has been resolved earlier in this process. A card that had Go meters must
    /// not have them blanked by one failed read of the login; a card that never had them has
    /// nothing to protect. In memory only, so the first refresh after a launch starts unprotected.
    private var hasResolvedGoKey = false

    /// Edge-triggers the rejected-key log the same way.
    private var loggedRejectedKey = false

    init(
        authStore: OpenCodeAuthStore = OpenCodeAuthStore(),
        usageClient: OpenCodeUsageClient = OpenCodeUsageClient(),
        usageScanner: OpenCodeUsageScanner = OpenCodeUsageScanner(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.usageScanner = usageScanner
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        // Go plan windows from `/zen/go/v1/usage` (Session/Weekly/Monthly + trend above the fold);
        // the spend tiles below sum combined OpenCode-hosted (Go + Zen) spend from local logs.
        [
            .percent(id: "opencode.session", provider: provider, title: "Session", isSessionWindow: true)
                .exportingLimit("session", unit: "percent"),
            .percent(id: "opencode.weekly", provider: provider, title: "Weekly")
                .exportingLimit("weekly", unit: "percent"),
            .percent(id: "opencode.monthly", provider: provider, title: "Monthly")
                .exportingLimit("monthly", unit: "percent"),
            .usageTrend(provider: provider)
                .exportingHistory(
                    scope: .machineLocal,
                    estimatedCost: false,
                    sourceNote: sourceNote
                )
        ] + WidgetDescriptor.spendTiles(provider: provider)
    }

    func hasLocalCredentials() async -> Bool {
        // Same sources as `refresh()`, through the same loaders: the local `opencode-go` key (`auth.json`,
        // or the credential table once OpenCode 2 runs the database), or any hosted usage in the local
        // database. Local-only, off the main actor. An unreadable auth.json is itself an OpenCode
        // footprint — enable the provider so `refresh()` can surface the actionable error. A database
        // that could not be asked for the login proves nothing by itself: like a first `refresh()`,
        // fall through to whether there is hosted usage to show.
        await loadOffMainActor { [authStore, usageScanner] in
            do {
                if try authStore.goAPIKey() != nil { return true }
            } catch OpenCodeUsageError.credentialDatabaseUnreadable {
                // Logged by the usage probe below when the same database fails there too.
            } catch {
                return true
            }
            return usageScanner.hasHostedUsage()
        }
    }

    func refresh() async -> ProviderSnapshot {
        // One clock for the whole refresh, so the scan cutoff, tiles, trend, and snapshot timestamp
        // can't straddle a midnight boundary.
        let refreshedAt = now()

        var goKey: String?
        var authReadError: OpenCodeUsageError?
        do {
            goKey = try await loadOffMainActor { [authStore] in try authStore.goAPIKey() }
            loggedAuthReadFailure = false
            if goKey != nil { hasResolvedGoKey = true }
        } catch OpenCodeUsageError.credentialDatabaseUnreadable(let detail) {
            let error = OpenCodeUsageError.credentialDatabaseUnreadable(detail: detail)
            if !loggedAuthReadFailure {
                loggedAuthReadFailure = true
                AppLog.warn(LogTag.plugin("opencode"), "credential database unreadable: \(detail)")
            }
            if hasResolvedGoKey {
                // This card had a Go login moments ago. Publishing tiles alone would replace and
                // cache over its meters because of one busy database, so fail the refresh instead.
                return ProviderSnapshot.error(provider: provider, error: error)
            }
            // No Go login seen this run: nothing to protect, and one unreadable database (a
            // leftover channel file, say) must not take the local tiles away.
            authReadError = error
        } catch let error as OpenCodeUsageError {
            authReadError = error
            if case .credentialsUnreadable(let detail) = error, !loggedAuthReadFailure {
                loggedAuthReadFailure = true
                AppLog.warn(LogTag.plugin("opencode"), "auth.json unreadable: \(detail)")
            }
        } catch {
            authReadError = .credentialsUnreadable(detail: error.localizedDescription)
        }

        var meterLines: [MetricLine] = []
        var plan: String?
        var rejectedKey = false
        if let goKey {
            switch await fetchGoMeters(apiKey: goKey) {
            case .meters(let lines):
                meterLines = lines
                plan = "Go"
            case .noSubscription:
                AppLog.info(LogTag.plugin("opencode"), "Go usage endpoint: no active subscription")
            case .failed(.unauthorized):
                // A rejected key will not start working on a retry, so it must not cost the local
                // spend tiles. It is the hard error only when there is nothing else to show, and
                // the card notice otherwise.
                rejectedKey = true
            case .failed(let error):
                // Anything else (network, server error, malformed body) is likely transient: fail
                // the refresh so the store keeps the last good meters and tiles and retries soon.
                return ProviderSnapshot.error(provider: provider, error: error)
            }
        }
        if rejectedKey, !loggedRejectedKey {
            AppLog.warn(LogTag.plugin("opencode"), "Go key rejected; serving local usage with a notice")
        }
        loggedRejectedKey = rejectedKey

        let scan: LogUsageScan?
        do {
            scan = try await usageScanner.scan(now: refreshedAt)
        } catch {
            if rejectedKey {
                // Nothing local to show after all, so the rejected key is the error, as it would
                // be with no database.
                return ProviderSnapshot.error(provider: provider, error: OpenCodeUsageError.unauthorized)
            }
            if meterLines.isEmpty {
                return ProviderSnapshot.error(provider: provider, error: error)
            }
            AppLog.warn(
                LogTag.plugin("opencode"),
                "local database unreadable; showing Go meters only: \(error.localizedDescription)"
            )
            scan = nil
        }

        var lines = meterLines
        if let scan {
            SpendTileMapper.appendTokenUsage(
                scan.series, to: &lines, now: refreshedAt,
                estimated: false,
                unknownModelsByDay: scan.unknownModelsByDay,
                modelUsage: scan.modelUsage,
                modelSourceNote: sourceNote
            )
            SpendTileMapper.appendUsageTrend(scan.series, to: &lines, now: refreshedAt, note: sourceNote)
        }

        if lines.isEmpty {
            if rejectedKey {
                return ProviderSnapshot.error(provider: provider, error: OpenCodeUsageError.unauthorized)
            }
            if goKey != nil {
                return ProviderSnapshot.error(provider: provider, error: OpenCodeUsageError.noGoSubscription)
            }
            if scan == nil {
                return ProviderSnapshot.error(
                    provider: provider, error: authReadError ?? OpenCodeUsageError.notLoggedIn
                )
            }
        }
        MetricLine.appendNoDataIfNeeded(&lines)

        // Without a Go subscription (Zen-only usage, or a key the endpoint answered with
        // `EntitlementError`), the three Go cap rows aren't applicable — hide them as documented
        // instead of rendering three "No data" meters above the local tiles. With meters present,
        // everything applies (`nil` keeps the legacy all-applicable behavior). A rejected key says
        // nothing about the subscription, so the rows stay applicable and the notice below stands in
        // for them.
        let applicableMetricIDs: Set<String>? = meterLines.isEmpty && !rejectedKey
            ? ["opencode.trend", "opencode.today", "opencode.yesterday", "opencode.last30"]
            : nil

        return ProviderSnapshot.make(
            provider: provider,
            plan: plan,
            lines: lines,
            refreshedAt: refreshedAt,
            usageHistory: scan.map {
                ProviderUsageHistory(
                    series: $0.series,
                    modelUsage: $0.modelUsage,
                    unknownModelsByDay: $0.unknownModelsByDay
                )
            },
            applicableMetricIDs: applicableMetricIDs,
            warning: rejectedKey ? OpenCodeUsageError.unauthorized.localizedDescription : nil,
            loginRequired: rejectedKey
        )
    }

    private enum GoFetch {
        case meters([MetricLine])
        case noSubscription
        case failed(OpenCodeUsageError)
    }

    private func fetchGoMeters(apiKey: String) async -> GoFetch {
        let response: HTTPResponse
        do {
            response = try await usageClient.fetchUsage(apiKey: apiKey)
        } catch {
            return .failed(.connectionFailed)
        }

        if response.statusCode == 401 {
            return .failed(.unauthorized)
        }
        if response.statusCode == 403, OpenCodeUsageMapper.errorType(in: response) == "EntitlementError" {
            return .noSubscription
        }
        guard (200..<300).contains(response.statusCode) else {
            return .failed(.requestFailed(response.statusCode))
        }
        do {
            return .meters(try OpenCodeUsageMapper.meterLines(response))
        } catch let error as OpenCodeUsageError {
            return .failed(error)
        } catch {
            return .failed(.invalidResponse)
        }
    }
}
