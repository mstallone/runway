import Foundation

protocol SQLiteAccessing: Sendable {
    func queryValue(path: String, sql: String) throws -> String?
    /// Read-only query whose rows come back as a JSON array of objects (sqlite3 `-json` output).
    /// `nil` means the database is absent or the query matched no rows.
    func queryJSONRows(path: String, sql: String) throws -> String?
}

struct SQLiteCLIAccessor: SQLiteAccessing {
    var processRunner: ProcessRunning

    init(processRunner: ProcessRunning = SystemProcessRunner()) {
        self.processRunner = processRunner
    }

    func queryValue(path: String, sql: String) throws -> String? {
        try query(path: path, sql: sql, json: false)
    }

    func queryJSONRows(path: String, sql: String) throws -> String? {
        try query(path: path, sql: sql, json: true)
    }

    private func query(path: String, sql: String, json: Bool) throws -> String? {
        // A normal sqlite3 open can create a missing database. Credential probes must be read-only and
        // side-effect free, so absence returns nil before a process is launched.
        guard try databaseExists(path) else { return nil }
        var result = try run(path: path, sql: sql, json: json)
        if !result.succeeded, result.stderr.contains("unable to open database file") {
            // A WAL-mode database whose -shm/-wal sidecars are missing cannot be opened with
            // -readonly (sqlite3 would have to create them). Nothing is writing such a database,
            // so an immutable open — read-only by definition, no sidecars needed — is safe.
            result = try run(
                path: immutableURI(forExpandedPath: expandHome(path)),
                sql: sql,
                json: json
            )
        }
        guard result.succeeded else {
            throw SQLiteError.queryFailed(result.stderr)
        }
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func immutableURI(forExpandedPath path: String) -> String {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return "file:\(encoded)?immutable=1"
    }

    private func run(
        path: String,
        sql: String,
        json: Bool = false
    ) throws -> ProcessResult {
        var arguments = ["-batch", "-noheader", "-readonly"]
        if json { arguments.append("-json") }
        arguments += [
            "-cmd", ".timeout 1000",
            expandHome(path),
            sql
        ]
        return try processRunner.run(
            executable: "/usr/bin/sqlite3",
            arguments: arguments,
            environment: [:],
            timeout: 5
        )
    }

    private func databaseExists(_ path: String) throws -> Bool {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: expandHome(path))
            return true
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return false
        }
    }
}

enum SQLiteError: Error, LocalizedError, Equatable {
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .queryFailed(let message):
            return message.isEmpty ? "SQLite query failed." : message
        }
    }
}
