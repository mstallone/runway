import XCTest
@testable import Runway

/// What one pass over the Go login reports besides the key: which database supplied it and what
/// could not be read on the way. `OpenCodeProvider.refresh()` decides from this whether a failed read
/// hit the database its key came from.
final class OpenCodeGoKeyLookupTests: XCTestCase {
    private typealias DB = OpenCodeDataDirectory
    private let liveGoAuth = #"{"opencode-go":{"type":"api","key":"sk-live"}}"#

    func testLookupNamesTheDatabaseThatSuppliedTheKey() throws {
        let dir = try DB(self)
        try dir.execute(DB.openCode2Tables)
        try dir.execute(DB.openCode2Tables + DB.credential(
            id: "c1", integration: "opencode-go", value: #"{"key":"oc_sk_next"}"#
        ), in: "opencode-next.db")
        let lookup = try dir.authStore().goKeyLookup()
        XCTAssertEqual(lookup.key, "oc_sk_next")
        XCTAssertEqual(lookup.source, dir.path("opencode-next.db"))
        XCTAssertTrue(lookup.unreadableDatabases.isEmpty)
        XCTAssertNil(lookup.authFileFailure)
    }

    func testLookupNamesTheDatabaseThatDeferredToTheAuthFile() throws {
        let dir = try DB(self)
        try dir.execute(DB.openCode118Tables)
        let lookup = try dir.authStore(auth: liveGoAuth).goKeyLookup()
        XCTAssertEqual(lookup.key, "sk-live")
        XCTAssertEqual(lookup.source, dir.path())

        let noDatabase = try DB(self)
        let fileOnly = try noDatabase.authStore(auth: liveGoAuth).goKeyLookup()
        XCTAssertEqual(fileOnly.key, "sk-live")
        XCTAssertEqual(fileOnly.source, noDatabase.path("auth.json"))
    }

    func testLookupKeepsUnreadableDatabasesWhenALaterOneHasAKey() throws {
        let dir = try DB(self)
        try dir.writeCorruptDatabase("opencode.db")
        try dir.execute(DB.openCode2Tables + DB.credential(
            id: "c1", integration: "opencode-go", value: #"{"key":"oc_sk_next"}"#
        ), in: "opencode-next.db")
        let store = dir.authStore()
        let lookup = try store.goKeyLookup()
        XCTAssertEqual(lookup.key, "oc_sk_next")
        XCTAssertEqual(lookup.source, dir.path("opencode-next.db"))
        XCTAssertEqual(Array(lookup.unreadableDatabases.keys), [dir.path()])
        XCTAssertEqual(try store.goAPIKey(), "oc_sk_next")
    }

    func testLookupReportsABadAuthFileAndUnreadableDatabasesTogether() throws {
        let dir = try DB(self)
        try dir.writeCorruptDatabase("opencode.db")
        try dir.execute(DB.openCode118Tables, in: "opencode-next.db")
        let store = dir.authStore(auth: "not json")
        let lookup = try store.goKeyLookup()
        XCTAssertNil(lookup.key)
        XCTAssertNil(lookup.source)
        XCTAssertEqual(Array(lookup.unreadableDatabases.keys), [dir.path()])
        XCTAssertNotNil(lookup.authFileFailure)
        // The throwing form reports the file, which is the one the user can fix.
        XCTAssertThrowsError(try store.goAPIKey()) { error in
            guard case OpenCodeUsageError.credentialsUnreadable = error else {
                return XCTFail("expected credentialsUnreadable, got \(error)")
            }
        }

        let noDatabase = try DB(self)
        let fileOnly = try noDatabase.authStore(auth: "not json").goKeyLookup()
        XCTAssertNil(fileOnly.key)
        XCTAssertNotNil(fileOnly.authFileFailure)
    }
}
