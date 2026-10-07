import Foundation

/// Which of the tables Runway reads one OpenCode database holds. Table names alone do not tell the
/// OpenCode version: 1.18 already creates `session_message` and `credential` (both empty) while it
/// still logs to `message` and keeps logins in `auth.json`, and a database created by OpenCode 2 has
/// no `message` table. Naming a missing table fails statement preparation, which would read as an
/// unreadable database, so every reader asks before it queries.
struct OpenCodeTables: OptionSet, Sendable {
    let rawValue: Int

    /// The OpenCode 1 message log.
    static let message = OpenCodeTables(rawValue: 1)
    /// The OpenCode 2 message log.
    static let sessionMessage = OpenCodeTables(rawValue: 2)
    /// The credential store OpenCode 2 uses.
    static let credential = OpenCodeTables(rawValue: 4)
    /// OpenCode's journal of applied schema migrations.
    static let migration = OpenCodeTables(rawValue: 8)

    static let messageLogs: OpenCodeTables = [.message, .sessionMessage]

    static let probeSQL = """
        SELECT group_concat(name) FROM sqlite_master
        WHERE type = 'table' AND name IN ('message','session_message','credential','migration');
        """

    static func probe(path: String, sqlite: SQLiteAccessing) throws -> OpenCodeTables {
        let names = try sqlite.queryValue(path: path, sql: probeSQL)?
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? []
        var tables: OpenCodeTables = []
        if names.contains("message") { tables.insert(.message) }
        if names.contains("session_message") { tables.insert(.sessionMessage) }
        if names.contains("credential") { tables.insert(.credential) }
        if names.contains("migration") { tables.insert(.migration) }
        return tables
    }
}
