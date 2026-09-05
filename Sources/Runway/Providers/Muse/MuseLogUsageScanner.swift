import Foundation

/// Builds daily token/cost estimates from Muse Code's local session journals.
///
/// Muse writes one append-only `session.jsonl` per session under
/// `$XDG_DATA_HOME/muse/sessions/YYYY/MM/DD/<id>/` (default `~/.local/share/muse`). Nested
/// `subagent/*/session.jsonl` files carry their own `model_completed` events and are counted
/// separately — the parent log does not already include them.
///
/// Each usage line is a `model_completed` envelope. Token buckets follow the OpenAI-Responses
/// convention Muse records: `input_tokens` includes cache reads/writes, and `output_tokens`
/// already includes reasoning. `goal_usage_attribution` repeats the same totals and is ignored.
struct MuseLogUsageScanner: Sendable {
    var environment: EnvironmentReading
    var homeDirectory: @Sendable () -> URL
    private let sessionScanner: IncrementalJSONLScanner<Entry>

    private static let sharedSessionScanner = IncrementalJSONLScanner<Entry>(
        logTag: LogTag.plugin("muse"),
        persistence: JSONLScanCachePersistence(namespace: "muse", schemaVersion: 1)
    )

    init(
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        incrementalScanner: IncrementalJSONLScanner<Entry>? = nil
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.sessionScanner = incrementalScanner ?? Self.sharedSessionScanner
    }

    static func flushPersistentCacheWrites() async {
        await sharedSessionScanner.flushPendingWrites()
    }

    /// Cheap local footprint probe used by provider auto-enablement. A sessions directory with no
    /// `session.jsonl` files is not a login — `scan()` would have nothing to read.
    func hasSessionFootprint() -> Bool {
        JSONLScanning.jsonlFiles(under: sessionsDirectory).contains { file in
            URL(fileURLWithPath: file.path).lastPathComponent == "session.jsonl"
        }
    }

    func scan(daysBack: Int = 30, now: Date = Date(), pricing: ModelPricing) async -> LogUsageScan? {
        let since = JSONLScanning.sinceDate(daysBack: daysBack, now: now)
        let directory = sessionsDirectory
        let identity = directory.resolvingSymlinksInPath().standardizedFileURL.path
        let discovered = Self.sessionFiles(under: directory, since: since)
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
        return Self.aggregate(Self.dedup(entries), since: since, pricing: pricing)
    }

    // MARK: - Paths

    /// `$XDG_DATA_HOME/muse`, else `~/.local/share/muse`.
    var dataDirectory: URL {
        if let raw = environment.value(for: "XDG_DATA_HOME")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        {
            return URL(fileURLWithPath: expandHome(raw))
                .appendingPathComponent("muse", isDirectory: true)
                .standardizedFileURL
        }
        return homeDirectory()
            .appendingPathComponent(".local/share/muse", isDirectory: true)
            .standardizedFileURL
    }

    var sessionsDirectory: URL {
        dataDirectory.appendingPathComponent("sessions", isDirectory: true)
    }

    // MARK: - Parse

    /// One priced `model_completed` event. `eventID` is the envelope `id` when present, used to
    /// drop a copied session that replayed the same completion.
    struct Entry: Codable, Sendable, Equatable {
        var eventID: String?
        var timestamp: Date
        var model: String
        var tokens: TokenBreakdown
    }

    static let sessionTailParser = JSONLTailParser<Entry>(parseChunk: { chunk, _ in
        (parseSessionFile(chunk), nil)
    })

    static func parseSessionFile(_ data: Data) -> [Entry] {
        let completedMarker = Data(#""model_completed""#.utf8)
        var entries: [Entry] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard line.range(of: completedMarker) != nil,
                  let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  let event = payload["event"] as? [String: Any],
                  event["kind"] as? String == "model_completed",
                  let usage = event["usage"] as? [String: Any],
                  let model = (event["model"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nilIfEmpty,
                  let timestamp = date(fromRecordedAt: object["recorded_at"]),
                  let tokens = tokenBreakdown(from: usage),
                  tokens.totalTokens > 0
            else { continue }

            entries.append(Entry(
                eventID: (object["id"] as? String)?.nilIfEmpty,
                timestamp: timestamp,
                model: model,
                tokens: tokens
            ))
        }
        return entries
    }

    /// Muse `input_tokens` is the full prompt, including cache buckets. `output_tokens` already
    /// includes reasoning, so reasoning is not added again.
    static func tokenBreakdown(from usage: [String: Any]) -> TokenBreakdown? {
        guard let input = nonnegativeInt(usage["input_tokens"]),
              let output = nonnegativeInt(usage["output_tokens"])
        else { return nil }

        let cacheReadRaw = nonnegativeInt(usage["cache_read_tokens"])
            ?? nonnegativeInt(usage["cached_tokens"])
            ?? 0
        let cacheWriteRaw = nonnegativeInt(usage["cache_write_tokens"]) ?? 0
        let cacheRead = min(cacheReadRaw, input)
        let cacheWrite = min(cacheWriteRaw, max(0, input - cacheRead))
        return TokenBreakdown(
            input: input - cacheRead - cacheWrite,
            cacheWrite5m: cacheWrite,
            cacheRead: cacheRead,
            output: output
        )
    }

    /// Muse records unix microseconds. Older or compacted envelopes may use milliseconds or seconds.
    static func date(fromRecordedAt raw: Any?) -> Date? {
        guard let value = ProviderParse.number(raw), value.isFinite, value > 0 else { return nil }
        let seconds: Double
        if value > 100_000_000_000_000_000 { // 1e17: nanoseconds
            seconds = value / 1_000_000_000
        } else if value > 100_000_000_000_000 { // 1e14: microseconds
            seconds = value / 1_000_000
        } else if value > 10_000_000_000 { // 1e10: milliseconds
            seconds = value / 1_000
        } else {
            seconds = value
        }
        return Date(timeIntervalSince1970: seconds)
    }

    static func dedup(_ entries: [Entry]) -> [Entry] {
        var seen: Set<String> = []
        return entries.filter { entry in
            guard let eventID = entry.eventID else { return true }
            return seen.insert(eventID).inserted
        }
    }

    static func aggregate(_ entries: [Entry], since: Date, pricing: ModelPricing) -> LogUsageScan {
        var accumulator = DailyUsageAccumulator()
        var dayKeys = DailyUsageAccumulator.DayKeyCache()
        for entry in entries where entry.timestamp >= since {
            let day = dayKeys.key(for: entry.timestamp)
            guard let cost = pricing.estimatedCostDollars(model: entry.model, tokens: entry.tokens) else {
                accumulator.addUnknownModel(day: day, model: entry.model)
                continue
            }
            accumulator.add(day: day, tokens: entry.tokens.totalTokens, cost: cost, model: entry.model)
        }
        return accumulator.build()
    }

    // MARK: - Discovery

    private static func sessionFiles(under directory: URL, since: Date) -> [JSONLScanning.DiscoveredFile] {
        JSONLScanning.jsonlFiles(under: directory).filter { file in
            file.mtime >= since && URL(fileURLWithPath: file.path).lastPathComponent == "session.jsonl"
        }
    }

    private static func nonnegativeInt(_ value: Any?) -> Int? {
        guard let number = ProviderParse.number(value), number.isFinite,
              number >= 0, number <= Double(Int.max), number.rounded(.towardZero) == number
        else { return nil }
        return Int(number)
    }

    private func expandHome(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return homeDirectory().path + String(path.dropFirst())
    }
}
