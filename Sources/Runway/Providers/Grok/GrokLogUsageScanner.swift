import Foundation
import os

/// Builds daily token/cost estimates for Grok from the Grok CLI's local activity records.
///
/// Grok 1.x writes authoritative per-turn usage to `~/.grok/sessions/**/updates.jsonl`. Older CLI
/// releases wrote token rows to the single `~/.grok/logs/unified.jsonl` file instead. The scanner
/// reads both, preferring the modern session record on days where both sources overlap, and emits
/// the same `DailyUsageSeries` shape the Claude/Codex spend tiles consume.
struct GrokLogUsageScanner: Sendable {
    var files: TextFileAccessing
    var environment: EnvironmentReading
    var homeDirectory: @Sendable () -> URL
    private let sessionScanner: IncrementalJSONLScanner<SessionEntry>
    private let readFailureReporter: UsageLogReadFailureReporter

    private static let sharedSessionScanner = IncrementalJSONLScanner<SessionEntry>(
        logTag: LogTag.plugin("grok"),
        persistence: JSONLScanCachePersistence(namespace: "grok", schemaVersion: 1)
    )

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        incrementalScanner: IncrementalJSONLScanner<SessionEntry>? = nil,
        readFailureWarning: UsageLogReadFailureReporter.Warning? = nil
    ) {
        self.files = files
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.sessionScanner = incrementalScanner ?? Self.sharedSessionScanner
        self.readFailureReporter = UsageLogReadFailureReporter(
            logTag: LogTag.plugin("grok"),
            warning: readFailureWarning
        )
    }

    static func flushPersistentCacheWrites() async {
        await sharedSessionScanner.flushPendingWrites()
    }

    private var grokHome: URL {
        if let raw = environment.value(for: "GROK_HOME")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return URL(fileURLWithPath: expandHome(raw)).standardizedFileURL
        }
        return homeDirectory().appendingPathComponent(".grok", isDirectory: true)
    }

    /// `~/.grok/logs/unified.jsonl`, or `$GROK_HOME/logs/unified.jsonl` when that env var is set.
    var logPath: String {
        grokHome.appendingPathComponent("logs/unified.jsonl").path
    }

    /// The legacy log's last parse, reused while its stat (path + size + mtime), history window,
    /// calendar configuration, and pricing snapshot are unchanged. The modern session source uses
    /// the per-file incremental scanner above; this smaller memo avoids re-reading the legacy source's
    /// one ever-growing file. Static because provider refreshes build fresh scanner values; the
    /// retained pricing object pins its instance identity.
    private struct ScanMemo {
        var path: String
        var size: Int
        var mtime: Date
        var since: Date
        var calendarKey: String
        var pricing: ModelPricing
        var scan: LogUsageScan
    }

    private static let memo = OSAllocatedUnfairLock<ScanMemo?>(initialState: nil)

    /// Scan the last `daysBack` days of modern session records plus the legacy global log. Returns
    /// `nil` when neither source exists/readable (the spend tiles then render "No data"); returns an
    /// empty `daily` when a source exists but has no usable token rows in the window.
    ///
    /// `async` and nonisolated (this is a plain `Sendable` struct, not `@MainActor`), so the whole-file
    /// read + parse runs off the main actor when a `@MainActor` provider `await`s it.
    func scan(daysBack: Int = 30, now: Date = Date(), pricing: ModelPricing) async -> LogUsageScan? {
        let since = JSONLScanning.sinceDate(daysBack: daysBack, now: now)
        async let sessionScan = scanSessions(since: since, pricing: pricing)
        let legacyScan = await scanLegacy(since: since, pricing: pricing)
        let modernScan = await sessionScan
        guard !Task.isCancelled else { return nil }
        return Self.merging(session: modernScan, legacy: legacyScan)
    }

    // MARK: - Grok 1.x session usage

    /// One model row from a persisted `turn_completed` usage ledger. `inputTokens` in that ledger
    /// includes both cache buckets, so parsing normalizes it into disjoint `TokenBreakdown` fields.
    struct SessionEntry: Codable, Sendable, Equatable {
        var promptID: String?
        var timestamp: Date
        var model: String
        var tokens: TokenBreakdown
        var reportedTotalTokens: Int
    }

    static let sessionTailParser = JSONLTailParser<SessionEntry>(parseChunk: { chunk, _ in
        (parseSessionFile(chunk), nil)
    })

    private func scanSessions(since: Date, pricing: ModelPricing) async -> LogUsageScan? {
        let directory = grokHome.appendingPathComponent("sessions", isDirectory: true)
        // Child sessions can contain usage absent from their coordinator. Include every ledger;
        // prompt-id dedup still drops forked parent replays.
        let discovered = Self.sessionLedgerFiles(under: directory, since: since)
        let identity = directory.resolvingSymlinksInPath().standardizedFileURL.path
        guard !discovered.isEmpty else {
            _ = await sessionScanner.items(
                from: [], since: since, cacheIdentity: identity, tailParser: Self.sessionTailParser
            )
            return nil
        }

        guard let entries = await sessionScanner.items(
            from: discovered,
            since: since,
            cacheIdentity: identity,
            tailParser: Self.sessionTailParser
        ), !Task.isCancelled else { return nil }
        return Self.aggregateSessionEntries(Self.dedupSessionEntries(entries), since: since, pricing: pricing)
    }

    /// Every durable `updates.jsonl` ledger under the sessions tree, including subagent and resumed
    /// child sessions. `summary.json` is not required: an unreadable or missing summary must not
    /// drop an otherwise valid usage ledger.
    private static func sessionLedgerFiles(under directory: URL, since: Date) -> [JSONLScanning.DiscoveredFile] {
        JSONLScanning.jsonlFiles(under: directory).filter { file in
            file.mtime >= since && URL(fileURLWithPath: file.path).lastPathComponent == "updates.jsonl"
        }
    }

    static func parseSessionFile(_ data: Data) -> [SessionEntry] {
        let completedMarker = Data(#""turn_completed""#.utf8)
        var entries: [SessionEntry] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard line.range(of: completedMarker) != nil,
                  let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let params = object["params"] as? [String: Any],
                  let update = params["update"] as? [String: Any],
                  update["sessionUpdate"] as? String == "turn_completed",
                  let usage = update["usage"] as? [String: Any],
                  let modelUsage = usage["modelUsage"] as? [String: Any],
                  let timestamp = sessionTimestamp(object: object, params: params)
            else { continue }

            let promptID = (update["prompt_id"] as? String)?.nilIfEmpty
            for (rawModel, rawUsage) in modelUsage {
                guard let model = rawModel.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                      let values = rawUsage as? [String: Any],
                      let fullInput = nonnegativeInt(values["inputTokens"]),
                      let output = nonnegativeInt(values["outputTokens"])
                else { continue }

                let cacheRead = min(nonnegativeInt(values["cachedReadTokens"]) ?? 0, fullInput)
                let cacheCreation = min(
                    nonnegativeInt(values["cacheCreationTokens"]) ?? 0,
                    fullInput - cacheRead
                )
                let tokens = TokenBreakdown(
                    input: fullInput - cacheRead - cacheCreation,
                    cacheWrite5m: cacheCreation,
                    cacheRead: cacheRead,
                    output: output
                )
                let total = nonnegativeInt(values["totalTokens"]) ?? tokens.totalTokens
                guard total > 0 else { continue }
                entries.append(SessionEntry(
                    promptID: promptID,
                    timestamp: timestamp,
                    model: model,
                    tokens: tokens,
                    reportedTotalTokens: total
                ))
            }
        }
        return entries
    }

    private static func sessionTimestamp(object: [String: Any], params: [String: Any]) -> Date? {
        let metadata = params["_meta"] as? [String: Any]
        if let milliseconds = ProviderParse.number(metadata?["agentTimestampMs"]),
           milliseconds.isFinite, milliseconds >= 0 {
            return Date(timeIntervalSince1970: milliseconds / 1000)
        }
        guard let seconds = ProviderParse.number(object["timestamp"]), seconds.isFinite, seconds >= 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func nonnegativeInt(_ value: Any?) -> Int? {
        guard let number = ProviderParse.number(value), number.isFinite,
              number >= 0, number <= Double(Int.max), number.rounded(.towardZero) == number
        else { return nil }
        return Int(number)
    }

    /// A fork can replay a parent's completed turn under the same prompt id. Keep one model row for
    /// that prompt; rows without an id cannot be proven duplicates and remain counted.
    static func dedupSessionEntries(_ entries: [SessionEntry]) -> [SessionEntry] {
        var seen: Set<String> = []
        return entries.filter { entry in
            guard let promptID = entry.promptID else { return true }
            return seen.insert(promptID + "\u{0}" + entry.model).inserted
        }
    }

    static func aggregateSessionEntries(
        _ entries: [SessionEntry],
        since: Date,
        pricing: ModelPricing
    ) -> LogUsageScan {
        var accumulator = DailyUsageAccumulator()
        var dayKeys = DailyUsageAccumulator.DayKeyCache()
        for entry in entries where entry.timestamp >= since {
            let day = dayKeys.key(for: entry.timestamp)
            guard let cost = pricing.estimatedCostDollars(
                model: entry.model,
                tokens: entry.tokens,
                applyLongContextRates: false
            ) else {
                accumulator.addUnknownModel(day: day, model: entry.model)
                continue
            }
            accumulator.add(
                day: day,
                tokens: entry.reportedTotalTokens,
                cost: cost,
                model: entry.model
            )
        }
        return accumulator.build()
    }

    // MARK: - Legacy unified log

    private func scanLegacy(since: Date, pricing: ModelPricing) async -> LogUsageScan? {
        let path = logPath
        guard files.exists(path) else {
            await readFailureReporter.update(checkedPaths: [path], failingPaths: [])
            return nil
        }
        let calendarKey = DailyUsageAccumulator.calendarMemoKey
        // Stat through FileManager: the memo is an optimization layered over the injectable file
        // accessor, so a test double without real files simply never hits it.
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let size = attributes?[.size] as? Int
        let mtime = attributes?[.modificationDate] as? Date
        if let size, let mtime,
           let cached = Self.memo.withLock({ $0 }),
           cached.path == path, cached.size == size, cached.mtime == mtime,
           cached.since == since, cached.calendarKey == calendarKey, cached.pricing === pricing
        {
            await readFailureReporter.update(checkedPaths: [path], failingPaths: [])
            return cached.scan
        }

        let text: String
        do {
            text = try files.readText(path)
            await readFailureReporter.update(checkedPaths: [path], failingPaths: [])
        } catch {
            await readFailureReporter.update(checkedPaths: [path], failingPaths: [path])
            return nil
        }
        let scan = Self.parse(text, since: since, pricing: pricing)
        if let size, let mtime {
            Self.memo.withLock {
                $0 = ScanMemo(
                    path: path, size: size, mtime: mtime, since: since,
                    calendarKey: calendarKey, pricing: pricing, scan: scan
                )
            }
        }
        return scan
    }

    /// Prefer the modern session ledger on any day represented there. Transitional CLI builds can
    /// write the same turn to both stores; day-level preference prevents a doubled total while still
    /// retaining older legacy-only days inside the 30-day window.
    static func merging(session: LogUsageScan?, legacy: LogUsageScan?) -> LogUsageScan? {
        guard let session else { return legacy }
        guard let legacy else { return session }
        let sessionDays = Set(session.modelUsage?.daily.map(\.date) ?? [])
            .union(session.unknownModelsByDay.keys)
        let filteredLegacy = LogUsageScan(
            series: DailyUsageSeries(daily: legacy.series.daily.filter { !sessionDays.contains($0.date) }),
            modelUsage: legacy.modelUsage.map { series in
                ModelUsageSeries(daily: series.daily.filter { !sessionDays.contains($0.date) })
            },
            unknownModelsByDay: legacy.unknownModelsByDay.filter { !sessionDays.contains($0.key) }
        )
        return DailyUsageAccumulator.merged([session, filteredLegacy])
    }

    /// Single chronological pass over the legacy append-only log. Model-carrying events update a per-`pid`
    /// "current model" (tracked regardless of date, so a session straddling the `since` boundary stays
    /// attributed); each in-window `inference_done` row is priced against its `pid`'s current model and
    /// bucketed by local calendar day.
    static func parse(_ text: String, since: Date, pricing: ModelPricing) -> LogUsageScan {
        var modelByPID: [Int: String] = [:]
        var accumulator = DailyUsageAccumulator()
        var dayKeys = DailyUsageAccumulator.DayKeyCache()

        text.enumerateLines { line, _ in
            // Cheap pre-filter before JSON parsing: only model-carrying events and token rows matter
            // (token rows contain "inference_done"; every model event's `msg` contains "model").
            guard line.contains("inference_done") || line.contains("model") else { return }
            guard let data = line.data(using: .utf8),
                  let object = ProviderParse.jsonObject(data),
                  let msg = object["msg"] as? String
            else { return }

            let ctx = object["ctx"] as? [String: Any] ?? [:]
            let pid = ProviderParse.number(object["pid"]).map { Int($0) }

            if let model = modelID(msg: msg, ctx: ctx) {
                if let pid { modelByPID[pid] = model }
                return
            }

            guard msg == "shell.turn.inference_done",
                  let promptTokens = ProviderParse.number(ctx["prompt_tokens"]),
                  let timestamp = (object["ts"] as? String).flatMap(RunwayISO8601.date(from:)),
                  timestamp >= since
            else { return }

            let completion = Int(ProviderParse.number(ctx["completion_tokens"]) ?? 0)
            let reasoning = Int(ProviderParse.number(ctx["reasoning_tokens"]) ?? 0)
            // `cached_prompt_tokens` is a subset of `prompt_tokens`, so total counts prompt once.
            let cached = min(ProviderParse.number(ctx["cached_prompt_tokens"]) ?? 0, promptTokens)
            let cacheRead = Int(cached)
            let inputNoCache = Int(max(0, promptTokens - cached))
            let output = completion + reasoning

            let day = dayKeys.key(for: timestamp)
            let totalTokens = Int(promptTokens) + output

            // Grok's token rows lack a model id; attribute via the row's process. Rows that can't be
            // priced (no attributable model, or a model no source can price) are excluded from every
            // displayed total — tokens, dollars, the trend, and the model breakdown — because mixing
            // measured tokens with unpriceable ones makes the figures incoherent. An unknown model's
            // name lands in `unknownModelsByDay` (the tile's warning triangle), the only place
            // unpriceable usage surfaces; unattributed rows have no name to warn about.
            guard let model = pid.flatMap({ modelByPID[$0] }) else { return }
            let tokenBreakdown = TokenBreakdown(input: inputNoCache, cacheRead: cacheRead, output: output)
            guard let cost = pricing.estimatedCostDollars(model: model, tokens: tokenBreakdown) else {
                if totalTokens > 0 {
                    accumulator.addUnknownModel(day: day, model: model)
                }
                return
            }
            accumulator.add(day: day, tokens: totalTokens, cost: cost, model: model)
        }

        return accumulator.build()
    }

    /// The model id carried by a model-change event, or `nil` for any other line. The Grok CLI signals
    /// the active model through several event shapes, all keyed by `pid`.
    private static func modelID(msg: String, ctx: [String: Any]) -> String? {
        let raw: Any?
        switch msg {
        case "model changed":
            raw = ctx["model"]
        case "model catalog: notifying clients":
            raw = ctx["current_model_id"]
        case "backend_search: model switch":
            raw = ctx["model"] ?? ctx["current_model_id"] ?? ctx["model_id"]
        case "subagent model resolved":
            raw = ctx["model_id"] ?? ctx["model"]
        default:
            return nil
        }
        guard let model = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty
        else { return nil }
        return model
    }

}
