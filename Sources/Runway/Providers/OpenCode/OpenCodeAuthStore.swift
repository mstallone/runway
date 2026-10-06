import Foundation

/// Reads the OpenCode credentials already on the machine. Local-only and read-only: never the
/// network, never a write. The `opencode-go` key is both the first-run detection signal and the
/// Bearer token for the usage API (`OpenCodeUsageClient`), so it lives behind one loader.
///
/// Where a login lives depends on which OpenCode last migrated the database, not on which tables
/// exist. OpenCode 1 (through 1.18.x) reads and writes only `auth.json`, even though 1.18 already
/// creates an empty `credential` table. OpenCode 2 reads and writes only the `credential` table of
/// each release-channel database. Its first run applies the `import_legacy_credentials` migration,
/// which copies `auth.json` into the table and leaves the file behind, so from then on the file is
/// stale for that database: a later login or logout only shows up in the table.
struct OpenCodeAuthStore: Sendable {
    var files: TextFileAccessing
    var environment: EnvironmentReading
    var homeDirectory: @Sendable () -> URL
    var sqlite: SQLiteAccessing

    /// Present once OpenCode 2 has taken over a database: the journal entry of the migration that
    /// imports `auth.json` into `credential`. A database created by OpenCode 2 carries it too.
    static let credentialImportSQL =
        "SELECT 1 FROM migration WHERE id = '20260805200742_import_legacy_credentials' LIMIT 1;"

    /// OpenCode's own choice of an integration's current credential: the active row, else the
    /// newest. Rows imported from `auth.json` have a NULL `active` flag.
    private static let currentRow = "ORDER BY active DESC, time_created DESC, id DESC LIMIT 1"

    /// The current `opencode-go` key of one database.
    static let goKeySQL = """
        SELECT CASE WHEN json_type(value,'$.key') = 'text' THEN json_extract(value,'$.key') END
        FROM credential
        WHERE integration_id = 'opencode-go'
        \(currentRow);
        """

    /// `[type, hasToken, time_created]` for the current `openai` row of one database. Only the facts
    /// attribution needs leave SQLite; the tokens never do.
    static let openAICredentialSQL = """
        SELECT json_array(
                 json_extract(value,'$.type'),
                 COALESCE(
                   (json_type(value,'$.access') = 'text'
                     AND trim(json_extract(value,'$.access'), char(9,10,13,32)) <> '')
                   OR (json_type(value,'$.refresh') = 'text'
                     AND trim(json_extract(value,'$.refresh'), char(9,10,13,32)) <> ''),
                   0),
                 time_created)
        FROM credential
        WHERE integration_id = 'openai'
        \(currentRow);
        """

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        sqlite: SQLiteAccessing = SQLiteCLIAccessor()
    ) {
        self.files = files
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.sqlite = sqlite
    }

    var dataDirectory: String {
        OpenCodePaths.dataDirectory(environment: environment, homeDirectory: homeDirectory())
    }

    var authFilePath: String {
        OpenCodePaths.authFilePath(dataDirectory: dataDirectory)
    }

    /// The non-empty `opencode-go` API key, or `nil` when the user has not logged into OpenCode Go.
    /// Databases are read in `OpenCodePaths.databaseFiles` order (stable channel first) and the first
    /// key wins. Each database answers from its own store, see `credentialStore(databasePath:tables:)`.
    /// With no database at all, `auth.json` answers.
    ///
    /// A present file, database, or data directory that can't be read throws `credentialsUnreadable`
    /// when no key was found, so broken storage is never mistaken for logout.
    func goAPIKey() throws -> String? {
        let paths: [String]
        do {
            paths = try OpenCodePaths.databaseFiles(in: dataDirectory)
        } catch {
            throw OpenCodeUsageError.credentialsUnreadable(detail: error.localizedDescription)
        }
        guard !paths.isEmpty else { return try authFileGoKey() }

        var failure: OpenCodeUsageError?
        for path in paths {
            do {
                let tables = try probeTables(path)
                let key: String?
                switch try credentialStore(databasePath: path, tables: tables) {
                case .table:
                    key = try tableGoKey(path)
                case .authFile(let tableFallback):
                    key = try authFileGoKey() ?? (tableFallback ? try tableGoKey(path) : nil)
                }
                if let key { return key }
            } catch let error as OpenCodeUsageError {
                failure = failure ?? error
            }
        }
        if let failure { throw failure }
        return nil
    }

    /// What Codex attribution needs to know about a database's `openai` login: whether it is the
    /// built-in ChatGPT / Codex OAuth flow, and when a `credential` row was created (`nil` for
    /// `auth.json`, which carries no timestamp). No secret is part of this value.
    struct OpenAICredential: Sendable, Equatable {
        var isOAuth: Bool
        var createdAtMs: Int?

        static let none = OpenAICredential(isOAuth: false, createdAtMs: nil)
    }

    /// The `openai` login that governs one release-channel database. OpenCode 2 keeps a separate
    /// credential store per channel, so `opencode.db` and `opencode-next.db` can hold different
    /// logins and each database's usage is judged by its own. OpenCode stores API-key and OAuth
    /// credentials under the same provider key, so the type must be checked before `openai` rows
    /// are attributed to the Codex card.
    ///
    /// `tables` is the caller's probe of that database. Throws `credentialsUnreadable` when the
    /// store can't be read or the row is malformed, so a locked database never reads as logout.
    func openAICredential(databasePath: String, tables: OpenCodeTables) throws -> OpenAICredential {
        switch try credentialStore(databasePath: databasePath, tables: tables) {
        case .table:
            return try tableOpenAICredential(databasePath) ?? .none
        case .authFile(let tableFallback):
            if let entry = try authObject()?["openai"] as? [String: Any] {
                let hasToken = ["access", "refresh"].contains { field in
                    ((entry[field] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty) != nil
                }
                return OpenAICredential(isOAuth: entry["type"] as? String == "oauth" && hasToken, createdAtMs: nil)
            }
            return tableFallback ? try tableOpenAICredential(databasePath) ?? .none : .none
        }
    }

    // MARK: - Which store is live

    private enum CredentialStore {
        /// OpenCode 2 runs this database: only its `credential` table counts, and a missing row is a
        /// logout that the leftover `auth.json` must not undo.
        case table
        /// OpenCode 2 has not taken over this database, so `auth.json` is the live store.
        /// `tableFallback`: the database has a `credential` table to consult for an integration the
        /// file does not list. Pre-release OpenCode 2 builds kept logins there without the import
        /// migration, and for OpenCode 1.18 the table is empty, so asking it costs nothing.
        case authFile(tableFallback: Bool)
    }

    private func credentialStore(databasePath: String, tables: OpenCodeTables) throws -> CredentialStore {
        let hasTable = tables.contains(.credential)
        guard hasTable, tables.contains(.migration) else { return .authFile(tableFallback: hasTable) }
        let imported = try readingCredentials {
            try sqlite.queryValue(path: databasePath, sql: Self.credentialImportSQL) != nil
        }
        return imported ? .table : .authFile(tableFallback: true)
    }

    private func probeTables(_ path: String) throws -> OpenCodeTables {
        try readingCredentials { try OpenCodeTables.probe(path: path, sqlite: sqlite) }
    }

    private func tableGoKey(_ path: String) throws -> String? {
        try readingCredentials { try sqlite.queryValue(path: path, sql: Self.goKeySQL) }?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private func authFileGoKey() throws -> String? {
        // Reads only the `opencode-go` entry, tolerant of unrelated sibling entries.
        guard let entry = try authObject()?["opencode-go"] as? [String: Any],
              let key = entry["key"] as? String
        else { return nil }
        return key.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private func tableOpenAICredential(_ path: String) throws -> OpenAICredential? {
        guard let json = try readingCredentials({ try sqlite.queryValue(path: path, sql: Self.openAICredentialSQL) })
        else { return nil }
        // The row's creation time bounds which usage counts, so one that is not a plausible
        // timestamp makes the row unusable rather than unbounded.
        guard let data = json.data(using: .utf8),
              let values = (try? JSONSerialization.jsonObject(with: data)) as? [Any], values.count == 3,
              let hasToken = ProviderParse.number(values[1]),
              let createdAtMs = ProviderParse.nonnegativeInt(values[2])
        else {
            throw OpenCodeUsageError.credentialsUnreadable(detail: "openai credential row is malformed")
        }
        return OpenAICredential(
            isOAuth: values[0] as? String == "oauth" && hasToken == 1,
            createdAtMs: createdAtMs
        )
    }

    /// Runs one SQLite read, turning its failure into `credentialsUnreadable` with sqlite3's message
    /// as the log detail (never a credential value).
    private func readingCredentials<T>(_ read: () throws -> T) throws -> T {
        do {
            return try read()
        } catch {
            throw OpenCodeUsageError.credentialsUnreadable(detail: error.localizedDescription)
        }
    }

    private func authObject() throws -> [String: Any]? {
        let text: String?
        do {
            text = try files.readTextIfPresent(authFilePath)
        } catch {
            throw OpenCodeUsageError.credentialsUnreadable(detail: error.localizedDescription)
        }
        guard let text else { return nil }
        guard let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            throw OpenCodeUsageError.credentialsUnreadable(detail: "auth.json is not valid JSON")
        }
        return object
    }
}
