import Foundation
import XCTest
@testable import Runway

final class MuseFirefoxAuthTests: XCTestCase {
    private var home: URL!
    private var firefoxRoot: URL { home.appendingPathComponent("Library/Application Support/Firefox") }
    private let token = String(repeating: "firefox-session-", count: 4)

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("MuseFirefox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: firefoxRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: home)
    }

    func testDiscoversRegisteredRelativeAndAbsoluteProfilesAndDeduplicatesFallback() throws {
        let personal = try database(at: firefoxRoot.appendingPathComponent("Profiles/abc.personal"))
        let work = try database(at: home.appendingPathComponent("Custom Work"))
        let extra = try database(at: firefoxRoot.appendingPathComponent("Profiles/new.profile"))
        try """
        [General]
        StartWithLastProfile=1
        [Profile0]
        Name=Personal
        IsRelative=1
        Path=Profiles/abc.personal
        [InstallABC]
        Default=Profiles/abc.personal
        [Profile1]
        Name=Work
        IsRelative=0
        Path=\(work.deletingLastPathComponent().path)
        [Profile2]
        Name=Missing
        IsRelative=1
        Path=Profiles/deleted
        """.write(to: firefoxRoot.appendingPathComponent("profiles.ini"), atomically: true, encoding: .utf8)

        let sources = FirefoxBrowserCookies.discoverSources(homeDirectory: home)
        XCTAssertEqual(Set(sources.map(\.databasePath)), Set([personal, work, extra].map { $0.resolvingSymlinksInPath().path }))
        XCTAssertEqual(sources.count, 3)
        XCTAssertEqual(sources[0].browserName, "Firefox (Personal)")
        XCTAssertEqual(sources[1].browserName, "Firefox (Work)")
        XCTAssertTrue(sources.allSatisfy { $0.format == .firefox })
        XCTAssertTrue(SakanaAuthStore.discoverSources(homeDirectory: home).isEmpty)
    }

    func testDefaultMuseDiscoveryLoadsFirefoxWithoutKeychain() throws {
        let path = try database(at: firefoxRoot.appendingPathComponent("Profiles/abc.personal"))
        try insert(token: token, into: path)
        let store = auth()
        XCTAssertTrue(store.hasCredentialFootprint())
        let session = try store.loadSession(allowInteraction: false)
        XCTAssertEqual(session.token, token)
        XCTAssertEqual(session.browserName, "Firefox (abc.personal)")
        XCTAssertEqual(try store.loadSession(allowInteraction: true).token, token)
    }

    func testIgnoresExpiredEmptyUnrelatedAndOldNamedCookies() throws {
        let path = try database(at: firefoxRoot.appendingPathComponent("Profiles/default"))
        for host in ["evilmeta.ai", "meta.ai.attacker.test", ".facebook.com"] {
            try insert(token: token, host: host, into: path)
        }
        try insert(token: token, name: "llm_sess", into: path)
        try insert(token: token, expiry: 1, into: path)
        try insert(token: "", into: path)
        let store = auth()
        XCTAssertFalse(store.hasCredentialFootprint())
        XCTAssertThrowsError(try store.loadSession(allowInteraction: false)) {
            XCTAssertEqual($0 as? MuseAuthError, .notLoggedIn)
        }
        for host in MuseAuthStore.cookieHosts {
            try insert(token: token, host: host, into: path)
        }
        XCTAssertTrue(store.hasCredentialFootprint())
        XCTAssertEqual(try store.loadSession(allowInteraction: false).token, token)
    }

    func testNewestFirefoxProfileAndContainerFallbackAfterRejection() throws {
        let older = String(repeating: "older-session-", count: 4)
        let container = String(repeating: "container-session-", count: 3)
        let personal = try database(at: firefoxRoot.appendingPathComponent("Profiles/personal"))
        let work = try database(at: firefoxRoot.appendingPathComponent("Profiles/work"))
        try insert(token: older, accessed: 100, into: personal)
        try insert(token: token, accessed: 300, into: work)
        try insert(token: container, accessed: 200, originAttributes: "^userContextId=1", into: work)
        let store = auth()
        XCTAssertEqual(try store.loadSession(allowInteraction: false).token, token)
        XCTAssertEqual(try store.loadSession(allowInteraction: false, excludingTokens: [token]).token, container)
        XCTAssertEqual(try store.loadSession(allowInteraction: false, excludingTokens: [token, container]).token, older)
        XCTAssertThrowsError(try store.loadSession(allowInteraction: false, excludingTokens: [token, container, older])) {
            XCTAssertEqual($0 as? MuseAuthError, .sessionExpired)
        }
    }

    func testNormalizesFirefoxAndChromiumTimestampsBeforeChoosingSession() throws {
        let path = try database(at: firefoxRoot.appendingPathComponent("Profiles/personal"))
        try insert(token: token, accessed: 1_800_000_000_000_000, into: path)
        let chrome = home.appendingPathComponent("Library/Application Support/Google/Chrome/Default/Cookies")
        try FileManager.default.createDirectory(at: chrome.deletingLastPathComponent(), withIntermediateDirectories: true)
        let chromeToken = String(repeating: "chrome-session-", count: 4)
        try execute("""
        CREATE TABLE cookies (host_key TEXT, name TEXT, value TEXT, encrypted_value BLOB, last_update_utc INTEGER);
        INSERT INTO cookies VALUES ('.meta.ai', 'llama_dev_sess', '\(chromeToken)', X'', 13444473599999999);
        """, at: chrome)
        let store = auth()
        XCTAssertEqual(try store.loadSession(allowInteraction: false).token, token)
        try execute("UPDATE cookies SET last_update_utc = 13444473600000001;", at: chrome)
        XCTAssertEqual(try store.loadSession(allowInteraction: false).token, chromeToken)
    }

    func testUnreadableProfileDoesNotHideAnotherSignedInProfile() throws {
        let bad = firefoxRoot.appendingPathComponent("Profiles/bad/cookies.sqlite")
        try FileManager.default.createDirectory(at: bad.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "not a database".write(to: bad, atomically: true, encoding: .utf8)
        let store = auth()
        XCTAssertFalse(store.hasCredentialFootprint())
        XCTAssertThrowsError(try store.loadSession(allowInteraction: false)) {
            XCTAssertEqual($0 as? MuseAuthError, .credentialStoreUnreadable)
        }
        let good = try database(at: firefoxRoot.appendingPathComponent("Profiles/good"))
        try insert(token: token, into: good)
        XCTAssertTrue(store.hasCredentialFootprint())
        XCTAssertEqual(try store.loadSession(allowInteraction: false).token, token)
    }

    private func auth() -> MuseAuthStore {
        let directory = home!
        return MuseAuthStore(keyReader: FirefoxUnexpectedKeyReader(), homeDirectory: { directory })
    }

    private func database(at directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("cookies.sqlite")
        try execute("""
        CREATE TABLE moz_cookies (
            id INTEGER PRIMARY KEY, originAttributes TEXT, name TEXT, value TEXT, host TEXT,
            path TEXT, expiry INTEGER, lastAccessed INTEGER, creationTime INTEGER,
            isSecure INTEGER, isHttpOnly INTEGER
        );
        """, at: path)
        return path
    }

    private func insert(
        token: String, name: String = "llama_dev_sess", host: String = ".meta.ai",
        expiry: Int64 = 4_102_444_800, accessed: Int64 = 1_800_000_000_000_000,
        originAttributes: String = "", into path: URL
    ) throws {
        try execute("""
        INSERT INTO moz_cookies (originAttributes, name, value, host, path, expiry, lastAccessed)
        VALUES ('\(originAttributes)', '\(name)', '\(token)', '\(host)', '/', \(expiry), \(accessed));
        """, at: path)
    }

    private func execute(_ sql: String, at path: URL) throws {
        let result = try SystemProcessRunner().run(
            executable: "/usr/bin/sqlite3", arguments: [path.path, sql], environment: [:], timeout: 5
        )
        guard result.succeeded else { throw SQLiteError.queryFailed(result.stderr) }
    }
}

private struct FirefoxUnexpectedKeyReader: SakanaSafeStorageKeyReading {
    func readPassword(service: String, allowInteraction: Bool) throws -> String? {
        XCTFail("Plaintext browser sessions must not access Keychain")
        throw SakanaBrowserCredentialError.manualReadDeferred
    }
}
