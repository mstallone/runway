import Foundation

/// Reads OpenCode's local SQLite logs (`~/.local/share/opencode/opencode*.db`, all release channels)
/// for the spend tiles and usage trend. Cookie-free: the per-message `cost` OpenCode writes for its
/// own hosted gateways is authoritative (Zen models aren't in our pricing snapshots), so it is summed
/// directly rather than re-priced. Go plan windows come from the usage API, not this scan.
///
/// OpenCode 1 logs to the `message` table and OpenCode 2 to `session_message`. An upgraded database
/// keeps both, with old messages copied into the new table under their original IDs, so both are
/// read and each message ID is counted once.
///
/// A `Sendable` struct (like the Grok scanner), `async` and nonisolated, so the SQLite reads run off the
/// main actor when the `@MainActor` provider `await`s it.
struct OpenCodeUsageScanner: Sendable {
    /// The OpenCode-hosted providerIDs we track: the Go subscription and the Zen pay-as-you-go gateway.
    /// Both write an authoritative `cost`; other (BYO-key) providerIDs log `cost: 0` and are out of scope.
    static let hostedProviderIDs = ["opencode-go", "opencode"]

    var sqlite: SQLiteAccessing
    var databasePaths: @Sendable () throws -> [String]
    private let readFailureReporter: UsageLogReadFailureReporter

    init(
        sqlite: SQLiteAccessing = SQLiteCLIAccessor(),
        databasePaths: @escaping @Sendable () throws -> [String] = OpenCodeUsageScanner.defaultDatabasePaths,
        readFailureWarning: UsageLogReadFailureReporter.Warning? = nil
    ) {
        self.sqlite = sqlite
        self.databasePaths = databasePaths
        self.readFailureReporter = UsageLogReadFailureReporter(
            logTag: LogTag.plugin("opencode"),
            warning: readFailureWarning
        )
    }

    static let defaultDatabasePaths: @Sendable () throws -> [String] = {
        let dir = OpenCodePaths.dataDirectory(
            environment: ProcessEnvironmentReader(),
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        return try OpenCodePaths.databaseFiles(in: dir)
    }

    /// Scan the last `daysBack` days. Returns `nil` only when there is no OpenCode database at all;
    /// a present-but-empty database yields an empty scan (idle tiles collapse to "No data" via
    /// `SpendTileMapper`). Throws `databaseUnreadable` when databases exist but none could be read.
    func scan(now: Date, daysBack: Int = 30) async throws -> LogUsageScan? {
        let paths: [String]
        do {
            paths = try databasePaths()
        } catch {
            // The data directory exists but couldn't be enumerated — same failure class as unreadable
            // databases, edge-logged through the reporter so a persistent failure doesn't spam.
            let marker = "<data directory>"
            let newlyFailing = await readFailureReporter.update(checkedPaths: [marker], failingPaths: [marker])
            if !newlyFailing.isEmpty {
                AppLog.warn(LogTag.plugin("opencode"), "data directory unreadable: \(error.localizedDescription)")
            }
            throw OpenCodeUsageError.databaseUnreadable
        }
        guard !paths.isEmpty else {
            await readFailureReporter.update(checkedPaths: [], failingPaths: [])
            return nil
        }

        // Same calendar bound the tiles/trend use. A wall-clock `now - daysBack×86400` cutoff sits
        // later the same day, so morning rows on the oldest day never leave SQLite.
        let tileSince = JSONLScanning.sinceDate(daysBack: daysBack, now: now)
        let cutoffMs = Int(tileSince.timeIntervalSince1970 * 1000)
        var rows: [Row] = []
        var checked: Set<String> = []
        var failures: [String: String] = [:]

        for path in paths {
            do {
                // A database with neither message table has no usage to read and does not vote on
                // whether the scan failed.
                let tables = try OpenCodeTables.probe(path: path, sqlite: sqlite)
                guard !tables.isDisjoint(with: .messageLogs) else { continue }
                checked.insert(path)
                if let json = try sqlite.queryValue(path: path, sql: Self.dataSQL(cutoffMs: cutoffMs, tables: tables)) {
                    rows.append(contentsOf: Self.parseRows(json))
                }
            } catch {
                checked.insert(path)
                failures[path] = error.localizedDescription
            }
        }
        // Per-path detail is logged only for newly failing paths (the reporter edge-triggers), so a
        // persistently locked database warns once, not on every 5-minute refresh.
        let newlyFailing = await readFailureReporter.update(checkedPaths: checked, failingPaths: Set(failures.keys))
        for path in newlyFailing.sorted() {
            AppLog.warn(LogTag.plugin("opencode"), "usage query failed for \(path): \(failures[path] ?? "unknown error")")
        }
        if !checked.isEmpty, failures.count == checked.count {
            throw OpenCodeUsageError.databaseUnreadable
        }

        var accumulator = DailyUsageAccumulator()
        var dayKeys = DailyUsageAccumulator.DayKeyCache()
        for row in Self.deduplicated(rows) {
            let date = Date(timeIntervalSince1970: row.ms / 1000)
            guard date >= tileSince else { continue }
            accumulator.add(
                day: dayKeys.key(for: date),
                tokens: row.tokens, cost: row.cost, model: row.model
            )
        }
        return accumulator.build()
    }

    /// Cheap local probe for `hasLocalCredentials()`: does any tracked database hold at least one hosted
    /// assistant row with a numeric cost? Read-only, no network. Failures are logged (this runs only
    /// during first-run / new-provider detection, so there's no refresh spam to throttle); an unreadable
    /// data directory counts as an OpenCode footprint so `refresh()` gets to surface the real error.
    func hasHostedUsage() -> Bool {
        let paths: [String]
        do {
            paths = try databasePaths()
        } catch {
            AppLog.warn(LogTag.plugin("opencode"), "usage probe: data directory unreadable: \(error.localizedDescription)")
            return true
        }
        for path in paths {
            do {
                let tables = try OpenCodeTables.probe(path: path, sqlite: sqlite)
                guard !tables.isDisjoint(with: .messageLogs) else { continue }
                if let value = try sqlite.queryValue(path: path, sql: Self.probeSQL(tables: tables)), !value.isEmpty {
                    return true
                }
            } catch {
                AppLog.warn(LogTag.plugin("opencode"), "usage probe failed for \(path): \(error.localizedDescription)")
            }
        }
        return false
    }

    // MARK: - Parsing

    /// One row per message ID, in first-seen order. When a message is in both tables the `message`
    /// original is the one counted, the same choice the Codex attribution scan makes, so an
    /// upgrade does not change what an old message contributes. Rows without an ID stay independent.
    private static func deduplicated(_ rows: [Row]) -> [Row] {
        var result: [Row] = []
        var indexByID: [String: Int] = [:]
        for row in rows {
            guard let id = row.id else {
                result.append(row)
                continue
            }
            if let index = indexByID[id] {
                if row.isLegacy, !result[index].isLegacy { result[index] = row }
            } else {
                indexByID[id] = result.count
                result.append(row)
            }
        }
        return result
    }

    private struct Row {
        var ms: Double
        var cost: Double
        var tokens: Int
        var model: String
        var id: String?
        /// From the OpenCode 1 `message` table.
        var isLegacy = false
    }

    /// Parse the `json_group_array(json_array(...))` payload: an array of
    /// `[time_created, cost, tokensTotal, modelID, providerID, id, isLegacy]`. Rows with a missing timestamp/cost
    /// or a non-string providerID are skipped at this boundary.
    private static func parseRows(_ json: String) -> [Row] {
        guard let data = json.data(using: .utf8),
              let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
        else { return [] }

        var rows: [Row] = []
        rows.reserveCapacity(parsed.count)
        for element in parsed {
            guard let entry = element as? [Any], entry.count >= 5,
                  let ms = ProviderParse.number(entry[0]),
                  let cost = ProviderParse.number(entry[1]), cost >= 0,
                  entry[4] is String
            else { continue }
            let tokens = ProviderParse.clampedTokenCount(entry[2])
            let model = (entry[3] as? String) ?? ""
            let id = entry.count >= 6 ? (entry[5] as? String)?.nilIfEmpty : nil
            let isLegacy = entry.count >= 7 && ProviderParse.number(entry[6]) == 1
            rows.append(Row(ms: ms, cost: cost, tokens: tokens, model: model, id: id, isLegacy: isLegacy))
        }
        return rows
    }

    // MARK: - SQL

    /// SQL literal built from `hostedProviderIDs`, so the tracked list has one source of truth.
    private static let providerFilter = "(" + hostedProviderIDs.map { "'\($0)'" }.joined(separator: ",") + ")"

    /// OpenCode 1 writes `message` rows with flat `role` / `modelID` / `providerID`. OpenCode 2 writes
    /// `session_message` rows with a `type` column and a nested `$.model`, and may omit
    /// `$.tokens.total`, so the total falls back to the sum of the token buckets. A completed
    /// compaction is billed model output too.
    private static let modelID = "COALESCE(json_extract(data,'$.model.id'),json_extract(data,'$.modelID'))"
    private static let providerID =
        "COALESCE(json_extract(data,'$.model.providerID'),json_extract(data,'$.providerID'))"
    private static let totalTokens = """
        COALESCE(json_extract(data,'$.tokens.total'),
                          COALESCE(json_extract(data,'$.tokens.input'),0)
                          + COALESCE(json_extract(data,'$.tokens.output'),0)
                          + COALESCE(json_extract(data,'$.tokens.reasoning'),0)
                          + COALESCE(json_extract(data,'$.tokens.cache.read'),0)
                          + COALESCE(json_extract(data,'$.tokens.cache.write'),0))
        """
    private static let messageKind = "json_extract(data,'$.role') = 'assistant'"
    private static let sessionMessageKind =
        "(type = 'assistant' OR (type = 'compaction' AND json_extract(data,'$.status') = 'completed'))"

    private static func rowsSQL(table: String, kind: String, cutoffMs: Int?) -> String {
        """
          SELECT id, time_created, data, \(table == "message" ? 1 : 0) AS legacy FROM \(table)
          WHERE \(cutoffMs.map { "time_created >= \($0)\n            AND " } ?? "")json_valid(data)
            AND \(kind)
            AND \(providerID) IN \(providerFilter)
            AND json_type(data,'$.cost') IN ('integer','real')
        """
    }

    /// The hosted rows of whichever message tables the database holds.
    private static func source(_ tables: OpenCodeTables, cutoffMs: Int?) -> String {
        var bodies: [String] = []
        if tables.contains(.message) {
            bodies.append(rowsSQL(table: "message", kind: messageKind, cutoffMs: cutoffMs))
        }
        if tables.contains(.sessionMessage) {
            bodies.append(rowsSQL(table: "session_message", kind: sessionMessageKind, cutoffMs: cutoffMs))
        }
        return "(\n" + bodies.joined(separator: "\n          UNION ALL\n") + "\n)"
    }

    static func dataSQL(cutoffMs: Int, tables: OpenCodeTables = .messageLogs) -> String {
        """
        SELECT json_group_array(json_array(
                 time_created,
                 json_extract(data,'$.cost'),
                 \(totalTokens),
                 \(modelID),
                 \(providerID),
                 id,
                 legacy))
        FROM \(source(tables, cutoffMs: cutoffMs));
        """
    }

    static func probeSQL(tables: OpenCodeTables = .messageLogs) -> String {
        "SELECT 1 FROM \(source(tables, cutoffMs: nil))\nLIMIT 1;"
    }
}
