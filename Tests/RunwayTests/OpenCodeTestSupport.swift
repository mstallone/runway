import XCTest
@testable import Runway

/// Stub that returns crafted payloads per database path and classifies the query by its SQL. Shared
/// by the OpenCode and Codex suites.
///
/// `tables` holds a database's table-probe output. By default a database has both message tables,
/// plus `credential` when `openAICredentials` has an entry for it. `openAICredentials` holds the
/// `[type, hasToken, time_created]` row the credential query returns, or `""` for an OpenCode 2
/// database with no `openai` row. A database without an entry is OpenCode 1 (no `credential` table).
final class OpenCodeFakeSQLite: SQLiteAccessing, @unchecked Sendable {
    var data: [String: String]
    var failing: Set<String>
    var tables: [String: String]
    var openAICredentials: [String: String]
    var lastDataSQL: String?
    var dataSQL: [String: String] = [:]

    init(
        data: [String: String] = [:],
        failing: Set<String> = [],
        tables: [String: String] = [:],
        openAICredentials: [String: String] = [:]
    ) {
        self.data = data
        self.failing = failing
        self.tables = tables
        self.openAICredentials = openAICredentials
    }

    func queryValue(path: String, sql: String) throws -> String? {
        if failing.contains(path) { throw SQLiteError.queryFailed("boom") }
        if sql == OpenCodeTables.probeSQL {
            let names = tables[path]
                ?? "message,session_message" + (openAICredentials[path] == nil ? "" : ",credential")
            return names.isEmpty ? nil : names
        }
        if sql == OpenCodeAuthStore.openAICredentialSQL {
            return openAICredentials[path]?.nilIfEmpty
        }
        if sql.contains("json_group_array") {
            lastDataSQL = sql
            dataSQL[path] = sql
            return data[path]
        }
        if sql.contains("SELECT 1") {
            let payload = data[path] ?? ""
            return payload.isEmpty || payload == "[]" ? nil : "1"
        }
        return nil
    }

    // JSON row queries are not used by the OpenCode readers.
    func queryJSONRows(path: String, sql: String) throws -> String? { nil }
}

/// A real OpenCode data directory on disk, read with the production `sqlite3` accessor, so the SQL the
/// readers generate runs against real databases. Table definitions are copied from an OpenCode 2
/// database (foreign keys dropped).
struct OpenCodeDataDirectory {
    static let messageTable = """
        CREATE TABLE message (id text PRIMARY KEY, session_id text NOT NULL, time_created integer NOT NULL,
          time_updated integer NOT NULL, data text NOT NULL);
        """
    static let sessionMessageTable = """
        CREATE TABLE session_message (id text PRIMARY KEY, session_id text NOT NULL, type text NOT NULL,
          seq integer NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL);
        """
    static let credentialTable = """
        CREATE TABLE credential (id text PRIMARY KEY, integration_id text, label text NOT NULL, value text NOT NULL,
          connector_id text, method_id text, active integer, time_created integer NOT NULL,
          time_updated integer NOT NULL);
        """
    /// Every table an upgraded OpenCode 2 database holds.
    static let openCode2Tables = messageTable + sessionMessageTable + credentialTable

    let url: URL

    init(_ testCase: XCTestCase) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("runway-opencode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        testCase.addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        self.url = url
    }

    func path(_ name: String = "opencode.db") -> String {
        url.path + "/" + name
    }

    /// Creates (or adds to) a database by running `sql` with the `sqlite3` CLI.
    func execute(_ sql: String, in name: String = "opencode.db") throws {
        let result = try SystemProcessRunner().run(
            executable: "/usr/bin/sqlite3", arguments: [path(name), sql], environment: [:], timeout: 5
        )
        guard result.succeeded else { throw SQLiteError.queryFailed(result.stderr) }
    }

    /// A file named like a database that `sqlite3` cannot read.
    func writeCorruptDatabase(_ name: String) throws {
        try Data(repeating: 0x58, count: 4096).write(to: url.appendingPathComponent(name))
    }

    /// An auth store over this directory with the production SQLite accessor. `auth` is the content
    /// of `auth.json`, or `nil` for no file.
    func authStore(auth: String? = nil) -> OpenCodeAuthStore {
        OpenCodeAuthStore(
            files: FakeFiles(auth.map { [path("auth.json"): $0] } ?? [:]),
            environment: FakeEnvironment(["OPENCODE_DATA_DIR": url.path]),
            homeDirectory: { URL(fileURLWithPath: "/nonexistent") }
        )
    }

    var databasePaths: @Sendable () throws -> [String] {
        let directory = url.path
        return { try OpenCodePaths.databaseFiles(in: directory) }
    }

    static func message(id: String, ms: Int, data: String) -> String {
        "INSERT INTO message VALUES ('\(id)','s',\(ms),\(ms),'\(data)');"
    }

    static func sessionMessage(id: String, type: String = "assistant", seq: Int, ms: Int, data: String) -> String {
        "INSERT INTO session_message VALUES ('\(id)','s','\(type)',\(seq),\(ms),\(ms),'\(data)');"
    }

    static func credential(
        id: String, integration: String, value: String, active: String = "1", created: String = "0", updated: Int = 0
    ) -> String {
        "INSERT INTO credential VALUES ('\(id)','\(integration)','default','\(value)',NULL,NULL,\(active),\(created),\(updated));"
    }
}
