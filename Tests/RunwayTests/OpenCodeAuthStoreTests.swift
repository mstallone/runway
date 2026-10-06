import XCTest
@testable import Runway

/// Go-key detection from `auth.json`, including tolerance of unrelated sibling entries (regression for the
/// atomic-decode gap that let one odd top-level value hide a valid `opencode-go` key) and the
/// broken-storage-is-not-logout distinction (unreadable/malformed files throw instead of reading as nil).
/// The OpenCode 2 cases read real databases through the production SQLite accessor.
final class OpenCodeAuthStoreTests: XCTestCase {
    private func store(_ json: String) -> OpenCodeAuthStore {
        store(files: FakeFiles(["/oc/auth.json": json]))
    }

    private func store(files: TextFileAccessing) -> OpenCodeAuthStore {
        OpenCodeAuthStore(
            files: files,
            environment: FakeEnvironment(["OPENCODE_DATA_DIR": "/oc"]),
            homeDirectory: { URL(fileURLWithPath: "/nonexistent") }
        )
    }

    /// `auth.json` governs an OpenCode 1 database, which has no `credential` table.
    private func isCodexOAuth(_ store: OpenCodeAuthStore) throws -> Bool {
        try store.openAICredential(databasePath: "/oc/opencode.db", tables: .message).isOAuth
    }

    /// The `openai` login of one real database, probed the way the Codex scanner does.
    private func openAICredential(
        _ store: OpenCodeAuthStore, _ path: String
    ) throws -> OpenCodeAuthStore.OpenAICredential {
        try store.openAICredential(
            databasePath: path, tables: OpenCodeTables.probe(path: path, sqlite: store.sqlite)
        )
    }

    private func assertCredentialsUnreadable(
        _ expression: @autoclosure () throws -> Any?, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            guard case OpenCodeUsageError.credentialsUnreadable = error else {
                return XCTFail("expected credentialsUnreadable, got \(error)", file: file, line: line)
            }
        }
    }

    private typealias DB = OpenCodeDataDirectory
    private let staleGoAuth = #"{"opencode-go":{"type":"api","key":"sk-stale"}}"#
    private let staleOAuthAuth = #"{"openai":{"type":"oauth","access":"stale","refresh":"stale"}}"#

    func testReadsGoKey() throws {
        XCTAssertEqual(try store(#"{"opencode-go":{"type":"api","key":"sk-abc"}}"#).goAPIKey(), "sk-abc")
    }

    func testToleratesNonObjectSiblingEntries() throws {
        // A future schema marker (string) and an array entry beside opencode-go must not hide the key.
        let json = #"{"$schema":"https://opencode.ai/auth.json","opencode-go":{"type":"api","key":"sk-xyz"},"weird":["a","b"]}"#
        XCTAssertEqual(try store(json).goAPIKey(), "sk-xyz")
    }

    func testCoexistsWithOtherProviderEntries() throws {
        let json = #"{"openai":{"type":"oauth","access":"x","refresh":"y"},"opencode-go":{"type":"api","key":"sk-1"}}"#
        XCTAssertEqual(try store(json).goAPIKey(), "sk-1")
    }

    func testDetectsCodexOAuthWithoutExposingTokens() throws {
        XCTAssertTrue(try isCodexOAuth(store(#"{"openai":{"type":"oauth","access":"access-token","refresh":"refresh-token"}}"#)))
        XCTAssertTrue(try isCodexOAuth(store(#"{"openai":{"type":"oauth","access":"access-token"}}"#)))
        XCTAssertTrue(try isCodexOAuth(store(#"{"openai":{"type":"oauth","refresh":"refresh-token"}}"#)))
    }

    func testDoesNotTreatOpenAIAPIKeyAsCodexOAuth() throws {
        XCTAssertFalse(try isCodexOAuth(store(#"{"openai":{"type":"api","key":"sk-openai"}}"#)))
        XCTAssertFalse(try isCodexOAuth(store(#"{"openai":{"type":"oauth","access":" ","refresh":" "}}"#)))
        XCTAssertFalse(try isCodexOAuth(store(#"{"anthropic":{"type":"oauth","access":"token"}}"#)))
        XCTAssertFalse(try isCodexOAuth(store(files: FakeFiles())))
    }

    func testMissingEmptyOrAbsentKeyIsNil() throws {
        XCTAssertNil(try store(#"{"opencode-go":{"type":"api"}}"#).goAPIKey())
        XCTAssertNil(try store(#"{"opencode-go":{"type":"api","key":"   "}}"#).goAPIKey())
        XCTAssertNil(try store(#"{"openai":{"type":"oauth"}}"#).goAPIKey())
        XCTAssertNil(try store(files: FakeFiles()).goAPIKey()) // absent file = not logged in
    }

    func testMalformedJSONThrowsCredentialsUnreadable() {
        XCTAssertThrowsError(try store("not json").goAPIKey()) { error in
            guard case OpenCodeUsageError.credentialsUnreadable = error else {
                return XCTFail("expected credentialsUnreadable, got \(error)")
            }
        }
    }

    func testUnreadablePresentFileThrowsCredentialsUnreadable() {
        // A present auth.json that can't be read (permissions, encoding) must not masquerade as logout.
        XCTAssertThrowsError(try store(files: UnreadableFiles(present: ["/oc/auth.json"])).goAPIKey()) { error in
            guard case OpenCodeUsageError.credentialsUnreadable = error else {
                return XCTFail("expected credentialsUnreadable, got \(error)")
            }
        }
    }

    // MARK: - Which store is live
    //
    // OpenCode 1 (through 1.18.x) keeps logins in auth.json. OpenCode 2 keeps them in each database's
    // credential table, imports auth.json once, and leaves the file behind. The table's existence
    // does not tell them apart (1.18 already creates it, empty); the import's journal entry does.

    private let liveGoAuth = #"{"opencode-go":{"type":"api","key":"sk-live"}}"#
    private let liveOAuthAuth = #"{"openai":{"type":"oauth","access":"a","refresh":"r"}}"#

    func testOpenCode118WithEmptyCredentialTableReadsTheAuthFile() throws {
        // The shape OpenCode 1.18.21 leaves on disk: credential and session_message exist and are
        // empty, every message is in `message`, and the login is in auth.json.
        let dir = try DB(self)
        try dir.execute(DB.openCode118Tables + DB.message(id: "m1", ms: 1, data:
            #"{"role":"assistant","providerID":"opencode-go","modelID":"glm-5.2","cost":1,"tokens":{"total":10}}"#))
        XCTAssertEqual(try dir.authStore(auth: liveGoAuth).goAPIKey(), "sk-live")
        XCTAssertEqual(
            try openAICredential(dir.authStore(auth: liveOAuthAuth), dir.path()),
            OpenCodeAuthStore.OpenAICredential(isOAuth: true, createdAtMs: nil)
        )
        // Logged out of OpenCode 1: nothing in the file, nothing in the empty table.
        XCTAssertNil(try dir.authStore(auth: "{}").goAPIKey())
        XCTAssertNil(try dir.authStore().goAPIKey())
        XCTAssertFalse(try openAICredential(dir.authStore(), dir.path()).isOAuth)
    }

    func testOpenCode1WithoutACredentialTableReadsTheAuthFile() throws {
        let dir = try DB(self)
        try dir.execute(DB.messageTable)
        XCTAssertEqual(try dir.authStore(auth: liveGoAuth).goAPIKey(), "sk-live")
        XCTAssertTrue(try openAICredential(dir.authStore(auth: liveOAuthAuth), dir.path()).isOAuth)
    }

    func testAuthFileAnswersWhenThereIsNoDatabase() throws {
        let dir = try DB(self)
        XCTAssertEqual(try dir.authStore(auth: liveGoAuth).goAPIKey(), "sk-live")
    }

    func testOpenCode2GoKeyComesFromTheCredentialTableNotTheStaleAuthFile() throws {
        for tables in [DB.openCode2Tables, DB.freshOpenCode2Tables] {
            let dir = try DB(self)
            try dir.execute(tables + DB.credential(
                id: "c1", integration: "opencode-go", value: #"{"type":"key","key":" oc_sk_live "}"#
            ))
            XCTAssertEqual(try dir.authStore(auth: staleGoAuth).goAPIKey(), "oc_sk_live")
            XCTAssertEqual(try dir.authStore().goAPIKey(), "oc_sk_live")
        }
    }

    func testOpenCode2GoLogoutIsNotRevivedByTheAuthFile() throws {
        // Logging out of OpenCode 2 deletes the row and leaves the imported auth.json behind.
        let dir = try DB(self)
        try dir.execute(DB.openCode2Tables + DB.credential(
            id: "c1", integration: "openai", value: #"{"type":"key","key":"sk-openai"}"#
        ))
        XCTAssertNil(try dir.authStore(auth: staleGoAuth).goAPIKey())
    }

    func testCredentialRowWithoutTheImportIsUsedOnlyWhenTheAuthFileHasNoEntry() throws {
        // Pre-release OpenCode 2 builds stored logins in the table before the import migration
        // existed. Without the journal entry the file stays the first answer.
        let dir = try DB(self)
        try dir.execute(DB.openCode118Tables + [
            DB.credential(id: "c1", integration: "opencode-go", value: #"{"type":"key","key":"oc_sk_table"}"#),
            DB.credential(id: "c2", integration: "openai", value: #"{"type":"oauth","access":"a"}"#, created: "500")
        ].joined())
        XCTAssertEqual(try dir.authStore().goAPIKey(), "oc_sk_table")
        XCTAssertEqual(try dir.authStore(auth: liveGoAuth).goAPIKey(), "sk-live")
        XCTAssertEqual(
            try openAICredential(dir.authStore(auth: liveGoAuth), dir.path()),
            OpenCodeAuthStore.OpenAICredential(isOAuth: true, createdAtMs: 500)
        )
        let apiKeyAuth = #"{"openai":{"type":"api","key":"sk-x"}}"#
        XCTAssertFalse(try openAICredential(dir.authStore(auth: apiKeyAuth), dir.path()).isOAuth)
    }

    func testStableChannelKeyWinsOverAnotherChannel() throws {
        let dir = try DB(self)
        try dir.execute(DB.openCode2Tables + DB.credential(
            id: "c1", integration: "opencode-go", value: #"{"type":"key","key":"oc_sk_next"}"#
        ), in: "opencode-next.db")
        try dir.execute(DB.openCode2Tables, in: "opencode.db")
        XCTAssertEqual(try dir.authStore(auth: staleGoAuth).goAPIKey(), "oc_sk_next")

        try dir.execute(DB.credential(
            id: "c1", integration: "opencode-go", value: #"{"type":"key","key":"oc_sk_stable"}"#
        ), in: "opencode.db")
        XCTAssertEqual(try dir.authStore().goAPIKey(), "oc_sk_stable")
    }

    func testDatabaseOpenCode2HasNotTakenOverKeepsTheAuthFileLive() throws {
        // Stable is on OpenCode 2 and logged out; another channel's database was never upgraded.
        // Each database answers from its own store, so the file still counts for that one.
        let dir = try DB(self)
        try dir.execute(DB.openCode2Tables, in: "opencode.db")
        try dir.execute(DB.openCode118Tables, in: "opencode-next.db")
        XCTAssertEqual(try dir.authStore(auth: liveGoAuth).goAPIKey(), "sk-live")
    }

    func testGoKeyTakesOpenCodesCurrentRow() throws {
        // OpenCode picks the active row, else the newest. An inactive row never beats the active one.
        let dir = try DB(self)
        try dir.execute(DB.openCode2Tables + [
            DB.credential(id: "c1", integration: "opencode-go", value: #"{"key":"inactive"}"#, active: "0", created: "900"),
            DB.credential(id: "c2", integration: "opencode-go", value: #"{"key":"current"}"#, created: "100")
        ].joined())
        XCTAssertEqual(try dir.authStore().goAPIKey(), "current")

        // Rows imported from auth.json carry no flag: the newest is the current one.
        let imported = try DB(self)
        try imported.execute(DB.openCode2Tables + [
            DB.credential(id: "c1", integration: "opencode-go", value: #"{"key":"older"}"#, active: "NULL", created: "100"),
            DB.credential(id: "c2", integration: "opencode-go", value: #"{"key":"newer"}"#, active: "NULL", created: "200")
        ].joined())
        XCTAssertEqual(try imported.authStore().goAPIKey(), "newer")
    }

    func testUnreadableDatabaseThrowsWhenNoKeyIsFound() throws {
        let dir = try DB(self)
        try dir.execute(DB.openCode2Tables)
        try dir.writeCorruptDatabase("opencode-next.db")
        assertCredentialsUnreadable(try dir.authStore(auth: staleGoAuth).goAPIKey())

        // A key found in a readable database is still returned.
        try dir.execute(DB.credential(id: "c1", integration: "opencode-go", value: #"{"key":"oc_sk_live"}"#))
        XCTAssertEqual(try dir.authStore().goAPIKey(), "oc_sk_live")
    }

    func testMalformedGoCredentialRowThrows() throws {
        let dir = try DB(self)
        try dir.execute(DB.openCode2Tables + DB.credential(id: "c1", integration: "opencode-go", value: "not json"))
        assertCredentialsUnreadable(try dir.authStore(auth: staleGoAuth).goAPIKey())
    }

    func testOpenCode2OpenAICredentialComesFromTheTableWithItsCreationTime() throws {
        let dir = try DB(self)
        try dir.execute(DB.openCode2Tables + DB.credential(
            id: "c1", integration: "openai", value: #"{"type":"oauth","access":"a","refresh":"r"}"#,
            created: "1786487065715"
        ))
        XCTAssertEqual(
            try openAICredential(dir.authStore(), dir.path()),
            OpenCodeAuthStore.OpenAICredential(isOAuth: true, createdAtMs: 1_786_487_065_715)
        )
    }

    func testOpenCode2CredentialTableOutranksTheStaleAuthFileBothWays() throws {
        let apiKey = try DB(self)
        try apiKey.execute(DB.openCode2Tables + DB.credential(
            id: "c1", integration: "openai", value: #"{"type":"key","key":"sk-x"}"#
        ))
        XCTAssertFalse(try openAICredential(apiKey.authStore(auth: staleOAuthAuth), apiKey.path()).isOAuth)

        let oauth = try DB(self)
        try oauth.execute(DB.openCode2Tables + DB.credential(
            id: "c1", integration: "openai", value: #"{"type":"oauth","refresh":"r"}"#
        ))
        let staleAPIKey = #"{"openai":{"type":"api","key":"sk-x"}}"#
        XCTAssertTrue(try openAICredential(oauth.authStore(auth: staleAPIKey), oauth.path()).isOAuth)
    }

    func testOpenCode2OpenAILogoutIsNotRevivedByTheAuthFile() throws {
        let dir = try DB(self)
        try dir.execute(DB.openCode2Tables)
        XCTAssertFalse(try openAICredential(dir.authStore(auth: staleOAuthAuth), dir.path()).isOAuth)
    }

    func testOpenAICredentialIsTheActiveRowNotAnInactiveOne() throws {
        // OpenCode 2 keeps earlier accounts as inactive rows. Only the active one decides.
        let apiKeyActive = try DB(self)
        try apiKeyActive.execute(DB.openCode2Tables + [
            DB.credential(id: "c1", integration: "openai", value: #"{"type":"oauth","access":"a"}"#, active: "0", created: "900"),
            DB.credential(id: "c2", integration: "openai", value: #"{"type":"key","key":"sk-x"}"#, created: "100")
        ].joined())
        XCTAssertFalse(try openAICredential(apiKeyActive.authStore(), apiKeyActive.path()).isOAuth)

        let oauthActive = try DB(self)
        try oauthActive.execute(DB.openCode2Tables + [
            DB.credential(id: "c1", integration: "openai", value: #"{"type":"key","key":"sk-x"}"#, active: "0", created: "900"),
            DB.credential(id: "c2", integration: "openai", value: #"{"type":"oauth","access":"a"}"#, created: "100")
        ].joined())
        XCTAssertEqual(
            try openAICredential(oauthActive.authStore(), oauthActive.path()),
            OpenCodeAuthStore.OpenAICredential(isOAuth: true, createdAtMs: 100)
        )
    }

    func testOAuthRowWithoutATokenIsNotCodexOAuth() throws {
        let dir = try DB(self)
        try dir.execute(DB.openCode2Tables + DB.credential(
            id: "c1", integration: "openai", value: #"{"type":"oauth","access":" ","refresh":7}"#
        ))
        XCTAssertFalse(try openAICredential(dir.authStore(), dir.path()).isOAuth)
    }

    func testEachChannelDatabaseIsJudgedByItsOwnCredential() throws {
        let dir = try DB(self)
        try dir.execute(DB.openCode2Tables + DB.credential(
            id: "c1", integration: "openai", value: #"{"type":"key","key":"sk-x"}"#
        ))
        try dir.execute(DB.openCode2Tables + DB.credential(
            id: "c1", integration: "openai", value: #"{"type":"oauth","access":"live"}"#
        ), in: "opencode-next.db")
        let store = dir.authStore()
        XCTAssertFalse(try openAICredential(store, dir.path()).isOAuth)
        XCTAssertTrue(try openAICredential(store, dir.path("opencode-next.db")).isOAuth)
    }

    func testImplausibleCredentialTimestampIsUnreadableNotATrap() throws {
        // `Int(Double)` traps past `Int.max`, and the timestamp bounds which usage counts.
        for raw in ["1e300", "-1", "9223372036854775808"] {
            let dir = try DB(self)
            try dir.execute(DB.openCode2Tables + DB.credential(
                id: "c1", integration: "openai", value: #"{"type":"oauth","access":"a"}"#, created: raw
            ))
            assertCredentialsUnreadable(try openAICredential(dir.authStore(), dir.path()))
        }
    }

    func testMalformedOpenAICredentialRowThrowsInsteadOfFallingBack() throws {
        let dir = try DB(self)
        try dir.execute(DB.openCode2Tables + DB.credential(id: "c1", integration: "openai", value: "not json"))
        assertCredentialsUnreadable(try openAICredential(dir.authStore(auth: staleOAuthAuth), dir.path()))
    }

    // MARK: - Database order and read-only access

    func testStableDatabaseIsListedFirst() throws {
        let dir = try DB(self)
        for name in ["opencode-next.db", "opencode.db", "opencode-beta.db", "opencode.db-wal", "other.db"] {
            try Data().write(to: dir.url.appendingPathComponent(name))
        }
        XCTAssertEqual(
            try OpenCodePaths.databaseFiles(in: dir.url.path).map { ($0 as NSString).lastPathComponent },
            ["opencode.db", "opencode-beta.db", "opencode-next.db"]
        )
    }

    func testCredentialsAreReadFromAWALDatabaseWhoseSidecarsAreGone() throws {
        // A WAL-mode database that nothing has open has no -shm/-wal files, and a plain read-only
        // open cannot create them in a directory that is not writable.
        let dir = try DB(self)
        try dir.execute("PRAGMA journal_mode=WAL;" + DB.openCode2Tables + DB.credential(
            id: "c1", integration: "opencode-go", value: #"{"key":"oc_sk_live"}"#
        ) + "PRAGMA wal_checkpoint(TRUNCATE);")
        for sidecar in ["opencode.db-wal", "opencode.db-shm"] {
            try? FileManager.default.removeItem(at: dir.url.appendingPathComponent(sidecar))
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.url.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.url.path)
        }
        XCTAssertEqual(try dir.authStore().goAPIKey(), "oc_sk_live")
    }
}

/// A file store whose present files exist but always fail to read, like a permission-denied auth.json.
final class UnreadableFiles: TextFileAccessing, @unchecked Sendable {
    let present: Set<String>
    init(present: Set<String>) { self.present = present }

    func exists(_ path: String) -> Bool { present.contains(path) }
    func readText(_ path: String) throws -> String {
        throw CocoaError(.fileReadNoPermission)
    }
    func writeText(_ path: String, _ text: String) throws {}
    func remove(_ path: String) throws {}
}
