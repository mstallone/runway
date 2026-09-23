import XCTest
@testable import Runway

@MainActor
func museLogScanner(tokens: Int) throws -> MuseLogUsageScanner {
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

let museNow = Date(timeIntervalSince1970: 1_800_000_000)
let museToken = String(repeating: "muse-session-", count: 4)
let museCookiePath = "/fixture/Chrome/Cookies"

func musePage(_ overrides: [String: Any] = [:]) -> String {
    var quota: [String: Any] = [
        "tier": "Muse Code Power Usage", "as_of": museNow.timeIntervalSince1970 - 30,
        "window_weighted_used": "24", "window_weighted_limit": "200", "window_resets_at": 1_800_005_000,
        "weekly_weighted_used": "340", "weekly_weighted_limit": "1000", "weekly_resets_at": 1_800_500_000
    ]
    quota.merge(overrides) { _, new in new }
    let json = String(decoding: try! JSONSerialization.data(withJSONObject: quota, options: [.sortedKeys]), as: UTF8.self)
    return "<html><script>var bootstrap = {\"subscription_quota_usage\" : \(json)};</script></html>"
}

func museResponse(_ body: String = musePage(), status: Int = 200, headers: [String: String] = [:]) -> HTTPResponse {
    HTTPResponse(statusCode: status, headers: headers, body: Data(body.utf8))
}

final class MuseCookieRows: SQLiteAccessing, @unchecked Sendable {
    var row: String?
    var queries: [String] = []

    init(token: String? = museToken, host: String = ".meta.ai", encrypted: Bool = false) {
        if let token {
            row = "\(Self.hex(host))|42|\(encrypted ? "encrypted" : "plain"):\(Self.hex(token))"
        }
    }

    static func hex(_ text: String) -> String {
        Data(text.utf8).map { String(format: "%02x", $0) }.joined()
    }

    func queryValue(path: String, sql: String) throws -> String? {
        queries.append(sql)
        return row
    }

    func queryJSONRows(path: String, sql: String) throws -> String? { nil }
}

struct MuseNoKeyReader: SakanaSafeStorageKeyReading {
    var error: SakanaBrowserCredentialError = .manualReadDeferred
    func readPassword(service: String, allowInteraction: Bool) throws -> String? { throw error }
}

func museAuth(rows: MuseCookieRows = MuseCookieRows(), keyReader: any SakanaSafeStorageKeyReading = MuseNoKeyReader()) -> MuseAuthStore {
    MuseAuthStore(
        sqlite: rows, files: FakeFiles([museCookiePath: ""]), keyReader: keyReader,
        sources: { [.init(browserName: "Chrome", databasePath: museCookiePath, safeStorageService: "Chrome Safe Storage")] }
    )
}

@MainActor
func makeMuseProvider(
    http: RoutingHTTPClient, rows: MuseCookieRows = MuseCookieRows(),
    logUsageScanner: MuseLogUsageScanner? = nil,
    now: @escaping @Sendable () -> Date = { museNow }
) -> MuseProvider {
    MuseProvider(
        authStore: museAuth(rows: rows), usageClient: MuseUsageClient(http: http),
        logUsageScanner: logUsageScanner ?? MuseLogUsageScanner(
            environment: FakeEnvironment(["XDG_DATA_HOME": "/tmp/runway-muse-empty"]),
            homeDirectory: { URL(fileURLWithPath: "/home/none") },
            incrementalScanner: IncrementalJSONLScanner<MuseLogUsageScanner.Entry>()
        ), now: now, pricing: { TestPricing.bundled }
    )
}

func museUsed(_ snapshot: ProviderSnapshot, label: String = "Five-Hour Usage") -> Double? {
    guard case .progress(_, let used, _, _, _, _, _) = snapshot.line(label: label) else { return nil }
    return used
}

final class MuseTestClock: @unchecked Sendable {
    var now = museNow
}
