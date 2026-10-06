import Foundation

/// Reads the OpenCode credentials already on the machine. Local-only and read-only: never the
/// network, never a write. The `opencode-go` key is both the first-run detection signal and the
/// Bearer token for the usage API (`OpenCodeUsageClient`), so it lives behind one loader.
///
/// OpenCode 2 moved credentials from `auth.json` into a `credential` table in each release-channel
/// database. It imports the file once and never deletes it, so once a database has that table the
/// file is stale: a later login or logout only shows up in the table.
struct OpenCodeAuthStore: Sendable {
    var files: TextFileAccessing
    var environment: EnvironmentReading
    var homeDirectory: @Sendable () -> URL
    var sqlite: SQLiteAccessing

    /// The current `opencode-go` key of one database. Ordering mirrors OpenCode (`active DESC,
    /// time_updated DESC, id DESC`), and the filter admits rows imported with a NULL `active` flag.
    static let goKeySQL = """
        SELECT CASE WHEN json_type(value,'$.key') = 'text' THEN json_extract(value,'$.key') END
        FROM credential
        WHERE integration_id = 'opencode-go' AND (active IS NULL OR active = 1)
        ORDER BY active DESC, time_updated DESC, id DESC
        LIMIT 1;
        """

    /// `[type, hasToken, time_created]` for the current `openai` row of one database, in the same
    /// order as the Go key. Only the facts attribution needs leave SQLite; the tokens never do.
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
        WHERE integration_id = 'openai' AND (active IS NULL OR active = 1)
        ORDER BY active DESC, time_updated DESC, id DESC
        LIMIT 1;
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
    /// Each database's `credential` table is read in path order and the first key wins. `auth.json`
    /// stands in only when no database has that table (OpenCode 1), so an OpenCode 2 logout, which
    /// deletes the row and leaves the file behind, is not undone by the stale file. The file read
    /// takes only the `opencode-go` entry and tolerates unrelated sibling entries.
    ///
    /// A present file, database, or data directory that can't be read throws `credentialsUnreadable`
    /// so broken storage is never mistaken for logout and never falls back to the file.
    func goAPIKey() throws -> String? {
        let paths: [String]
        do {
            paths = try OpenCodePaths.databaseFiles(in: dataDirectory)
        } catch {
            throw OpenCodeUsageError.credentialsUnreadable(detail: error.localizedDescription)
        }
        var hasCredentialTable = false
        var failure: Error?
        for path in paths {
            do {
                guard try OpenCodeTables.probe(path: path, sqlite: sqlite).contains(.credential) else { continue }
                hasCredentialTable = true
                if let key = try sqlite.queryValue(path: path, sql: Self.goKeySQL)?
                    .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
                    return key
                }
            } catch {
                failure = failure ?? error
            }
        }
        if let failure {
            throw OpenCodeUsageError.credentialsUnreadable(detail: failure.localizedDescription)
        }
        if hasCredentialTable { return nil }

        guard let object = try authObject() else { return nil }
        guard let entry = object["opencode-go"] as? [String: Any],
              let key = entry["key"] as? String
        else { return nil }
        return key.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    /// What Codex attribution needs to know about a database's `openai` login: whether it is the
    /// built-in ChatGPT / Codex OAuth flow, and when an OpenCode 2 credential row was created
    /// (`nil` for `auth.json`, which carries no timestamp). No secret is part of this value.
    struct OpenAICredential: Sendable, Equatable {
        var isOAuth: Bool
        var createdAtMs: Int?
    }

    /// The `openai` login that governs one release-channel database. OpenCode keeps a separate
    /// credential store per channel, so `opencode.db` and `opencode-next.db` can hold different
    /// logins and each database's usage is judged by its own. OpenCode stores API-key and OAuth
    /// credentials under the same provider key, so the type must be checked before `openai` rows
    /// are attributed to the Codex card.
    ///
    /// `tables` is the caller's probe of that database. With a `credential` table, a missing row is
    /// a logout. Without one (OpenCode 1), `auth.json` is still live. Throws `credentialsUnreadable`
    /// when the store can't be read or the row is malformed, so a locked database never revives the
    /// stale file.
    func openAICredential(databasePath: String, tables: OpenCodeTables) throws -> OpenAICredential {
        guard tables.contains(.credential) else {
            guard let entry = try authObject()?["openai"] as? [String: Any] else {
                return OpenAICredential(isOAuth: false, createdAtMs: nil)
            }
            let hasToken = ["access", "refresh"].contains { field in
                ((entry[field] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty) != nil
            }
            return OpenAICredential(isOAuth: entry["type"] as? String == "oauth" && hasToken, createdAtMs: nil)
        }

        let json: String?
        do {
            json = try sqlite.queryValue(path: databasePath, sql: Self.openAICredentialSQL)
        } catch {
            throw OpenCodeUsageError.credentialsUnreadable(detail: error.localizedDescription)
        }
        guard let json else { return OpenAICredential(isOAuth: false, createdAtMs: nil) }
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
