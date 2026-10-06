import XCTest
@testable import Runway

/// The shared read / status / save / delete behavior behind every user-supplied API key (OpenRouter,
/// Z.ai). Provider suites cover only their own wiring: config paths, env-var names, and error mapping.
final class UserAPIKeyStoreTests: XCTestCase {
    private static let paths = ["~/.config/runway/example.json", "~/.config/example/key.json"]
    private static let savedKey = [paths[0]: #"{"apiKey":"file-key"}"#]
    private static let envKey = ["EXAMPLE_API_KEY": "env-key"]

    private enum StoreError: Error, Equatable { case missingKey, saveFailed, deleteFailed }

    private func makeStore(_ files: FakeFiles = FakeFiles(), env: [String: String] = [:]) -> UserAPIKeyStore {
        UserAPIKeyStore(
            configPaths: Self.paths,
            environmentNames: ["EXAMPLE_API_KEY", "EXAMPLE_KEY"],
            files: files,
            environment: FakeEnvironment(env),
            makeError: { failure in
                switch failure {
                case .missingKey: return StoreError.missingKey
                case .saveFailed: return StoreError.saveFailed
                case .deleteFailed: return StoreError.deleteFailed
                }
            }
        )
    }

    // MARK: - Reading

    func testPrefersConfigFileOverEnvironment() {
        // Config file wins so editing it to rotate the key isn't shadowed by a stale env value.
        XCTAssertEqual(makeStore(FakeFiles(Self.savedKey), env: Self.envKey).loadKey(), "file-key")
    }

    func testFallsBackToEnvironmentInNameOrder() {
        XCTAssertEqual(makeStore(env: Self.envKey).loadKey(), "env-key")
        XCTAssertEqual(makeStore(env: ["EXAMPLE_KEY": "second"]).loadKey(), "second")
        XCTAssertEqual(makeStore(env: ["EXAMPLE_API_KEY": "first", "EXAMPLE_KEY": "second"]).loadKey(), "first")
        XCTAssertEqual(makeStore(env: ["EXAMPLE_API_KEY": "  ", "EXAMPLE_KEY": "second"]).loadKey(), "second")
    }

    func testReadsEveryAcceptedConfigFileShape() {
        let shapes: [(text: String, key: String?)] = [
            (#"{"apiKey":"k"}"#, "k"),
            (#"{ "api_key": "k" }"#, "k"),
            (#"{"key":" k "}"#, "k"),
            ("  k\n", "k"),
            (#"{"other":"k"}"#, nil),
            ("   ", nil),
        ]
        for shape in shapes {
            // The alternate path is read exactly like the primary one.
            for path in Self.paths {
                XCTAssertEqual(makeStore(FakeFiles([path: shape.text])).loadKey(), shape.key, "\(path): \(shape.text)")
            }
        }
    }

    func testIgnoresBlankConfigAndUsesEnvironment() {
        XCTAssertEqual(makeStore(FakeFiles([Self.paths[0]: "   "]), env: Self.envKey).loadKey(), "env-key")
    }

    func testReturnsNilWhenNoKeyAnywhere() {
        XCTAssertNil(makeStore().loadKey())
    }

    // MARK: - Status

    func testKeyStatusReportsAllFourStates() {
        XCTAssertEqual(makeStore().keyStatus(), .notSet)
        XCTAssertEqual(makeStore(env: Self.envKey).keyStatus(), .fromEnvironment)
        XCTAssertEqual(makeStore(FakeFiles(Self.savedKey)).keyStatus(), .saved)
        XCTAssertEqual(makeStore(FakeFiles(Self.savedKey), env: Self.envKey).keyStatus(), .overrideActive)
        // A saved key plus an env key is an override even when the values match — config wins, so the
        // saved source is the one in use.
        XCTAssertEqual(
            makeStore(FakeFiles(Self.savedKey), env: ["EXAMPLE_API_KEY": "file-key"]).keyStatus(),
            .overrideActive
        )
    }

    // MARK: - Save

    func testSaveWritesTrimmedJSONToThePrimaryPath() throws {
        let files = FakeFiles()
        let store = makeStore(files)

        try store.saveKey("  new-key  ")

        XCTAssertEqual(files.files, [Self.paths[0]: #"{"apiKey":"new-key"}"#])
        XCTAssertEqual(store.loadKey(), "new-key")
    }

    func testSaveRejectsEmptyKeyWithTheMappedError() {
        let files = FakeFiles()

        XCTAssertThrowsError(try makeStore(files).saveKey("   ")) { error in
            XCTAssertEqual(error as? StoreError, .missingKey)
        }
        XCTAssertTrue(files.files.isEmpty)
    }

    func testSavedKeyOverridesEnvironment() throws {
        let store = makeStore(env: Self.envKey)

        try store.saveKey("saved-key")

        XCTAssertEqual(store.loadKey(), "saved-key")
        XCTAssertEqual(store.keyStatus(), .overrideActive)
    }

    // MARK: - Delete

    func testDeleteFallsBackToEnvironment() throws {
        let files = FakeFiles(Self.savedKey)
        let store = makeStore(files, env: Self.envKey)

        try store.deleteKey()

        XCTAssertTrue(files.files.isEmpty)
        XCTAssertEqual(store.keyStatus(), .fromEnvironment)
        XCTAssertEqual(store.loadKey(), "env-key")
    }

    func testDeleteClearsEveryConfigPath() throws {
        // A key in the alternate config path must also be cleared, or it resurfaces after the primary
        // file is deleted and the Settings "clear" appears not to work.
        for seeded in [
            [Self.paths[0]: #"{"apiKey":"primary"}"#, Self.paths[1]: "alternate"],
            [Self.paths[1]: "alternate"],
        ] {
            let files = FakeFiles(seeded)
            let store = makeStore(files)
            XCTAssertEqual(store.keyStatus(), .saved)

            try store.deleteKey()

            XCTAssertTrue(files.files.isEmpty)
            XCTAssertEqual(store.keyStatus(), .notSet)
            XCTAssertNil(store.loadKey())
        }
    }

    func testDeleteIsNoOpWhenNoFileExists() throws {
        let store = makeStore()

        XCTAssertNoThrow(try store.deleteKey())
        XCTAssertEqual(store.keyStatus(), .notSet)
    }
}
