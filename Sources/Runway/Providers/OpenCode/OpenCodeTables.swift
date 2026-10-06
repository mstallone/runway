import Foundation

/// Which of the tables Runway reads one OpenCode database holds. OpenCode 1 logs assistant messages
/// to `message` and keeps credentials in `auth.json`; OpenCode 2 logs to `session_message` and keeps
/// credentials in `credential`. An upgraded install usually holds all three, but a fresh OpenCode 2
/// database can lack `message`. Naming a missing table fails statement preparation, which would read
/// as an unreadable database, so every reader asks before it queries.
struct OpenCodeTables: OptionSet, Sendable {
    let rawValue: Int

    /// The OpenCode 1 message log.
    static let message = OpenCodeTables(rawValue: 1)
    /// The OpenCode 2 message log.
    static let sessionMessage = OpenCodeTables(rawValue: 2)
    /// The OpenCode 2 credential store.
    static let credential = OpenCodeTables(rawValue: 4)

    static let messageLogs: OpenCodeTables = [.message, .sessionMessage]

    static let probeSQL = """
        SELECT group_concat(name) FROM sqlite_master
        WHERE type = 'table' AND name IN ('message','session_message','credential');
        """

    static func probe(path: String, sqlite: SQLiteAccessing) throws -> OpenCodeTables {
        let names = try sqlite.queryValue(path: path, sql: probeSQL)?
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? []
        var tables: OpenCodeTables = []
        if names.contains("message") { tables.insert(.message) }
        if names.contains("session_message") { tables.insert(.sessionMessage) }
        if names.contains("credential") { tables.insert(.credential) }
        return tables
    }
}
