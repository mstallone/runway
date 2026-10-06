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

    // MARK: - OpenCode 2 credential table

    func testGoKeyComesFromTheCredentialTableNotTheStaleAuthFile() throws {
        let dir = try DB(self)
        try dir.execute(DB.openCode2Tables + DB.credential(
            id: "c1", integration: "opencode-go", value: #"{"type":"key","key":" oc_sk_live "}"#
        ))
        XCTAssertEqual(try dir.authStore(auth: staleGoAuth).goAPIKey(), "oc_sk_live")
        XCTAssertEqual(try dir.authStore().goAPIKey(), "oc_sk_live")
    }

    func testGoKeyIsFoundInAnyChannelDatabase() throws {
        let dir = try DB(self)
        try dir.execute(DB.openCode2Tables)
        try dir.execute(DB.openCode2Tables + DB.credential(
            id: "c1", integration: "opencode-go", value: #"{"type":"key","key":"oc_sk_next"}"#
        ), in: "opencode-next.db")
        XCTAssertEqual(try dir.authStore(auth: staleGoAuth).goAPIKey(), "oc_sk_next")
    }

    func testOpenCode2GoLogoutIsNotRevivedByTheAuthFile() throws {
        // Logging out of OpenCode 2 deletes the row and leaves the imported auth.json behind.
        let dir = try DB(self)
        try dir.execute(DB.openCode2Tables + DB.credential(
            id: "c1", integration: "openai", value: #"{"type":"key","key":"sk-openai"}"#
        ))
        XCTAssertNil(try dir.authStore(auth: staleGoAuth).goAPIKey())
    }

    func testGoKeyFallsBackToTheAuthFileWhenNoDatabaseHasACredentialTable() throws {
        let dir = try DB(self)
        try dir.execute(DB.messageTable)
        XCTAssertEqual(try dir.authStore(auth: staleGoAuth).goAPIKey(), "sk-stale")
    }

    func testGoKeyTakesTheCurrentRow() throws {
        // An inactive row never wins, however new. Among usable rows the active flag outranks an
        // unflagged import, then the latest update.
        let dir = try DB(self)
        try dir.execute(DB.openCode2Tables + [
            DB.credential(id: "c1", integration: "opencode-go", value: #"{"key":"inactive"}"#, active: "0", updated: 900),
            DB.credential(id: "c2", integration: "opencode-go", value: #"{"key":"imported"}"#, active: "NULL", updated: 800),
            DB.credential(id: "c3", integration: "opencode-go", value: #"{"key":"older"}"#, updated: 100),
            DB.credential(id: "c4", integration: "opencode-go", value: #"{"key":"current"}"#, updated: 200)
        ].joined())
        XCTAssertEqual(try dir.authStore().goAPIKey(), "current")
    }

    func testUnreadableCredentialDatabaseThrowsInsteadOfFallingBack() throws {
        let dir = try DB(self)
        try dir.execute(DB.openCode2Tables)
        try dir.writeCorruptDatabase("opencode-next.db")
        assertCredentialsUnreadable(try dir.authStore(auth: staleGoAuth).goAPIKey())
    }

    func testMalformedGoCredentialRowThrows() throws {
        let dir = try DB(self)
        try dir.execute(DB.openCode2Tables + DB.credential(id: "c1", integration: "opencode-go", value: "not json"))
        assertCredentialsUnreadable(try dir.authStore(auth: staleGoAuth).goAPIKey())
    }

    func testOpenAICredentialComesFromTheCredentialTableWithItsCreationTime() throws {
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

    func testCredentialTableOutranksTheStaleAuthFileBothWays() throws {
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
        let loggedOut = try DB(self)
        try loggedOut.execute(DB.openCode2Tables)
        XCTAssertFalse(try openAICredential(loggedOut.authStore(auth: staleOAuthAuth), loggedOut.path()).isOAuth)

        // An OpenCode 1 database has no credential table, so auth.json is still its live login.
        let openCode1 = try DB(self)
        try openCode1.execute(DB.messageTable)
        XCTAssertEqual(
            try openAICredential(openCode1.authStore(auth: staleOAuthAuth), openCode1.path()),
            OpenCodeAuthStore.OpenAICredential(isOAuth: true, createdAtMs: nil)
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
