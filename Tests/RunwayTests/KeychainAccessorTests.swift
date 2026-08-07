import LocalAuthentication
import Security
import XCTest
@testable import Runway

/// Minimal lock-guarded box for cross-thread event recording in the gate tests.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.withLock { body(&value) }
    }
}

private final class ManualRefreshApprovalProbe: @unchecked Sendable {
    struct State {
        var active = 0
        var maximumActive = 0
        var readAttempts = 0
        var promptedProviderIDs: Set<String> = []
        var unavailableProviderIDs: Set<String> = []
    }

    let state = Locked(State())

    func read(providerID: String) {
        state.withLock { $0.readAttempts += 1 }
        InteractiveKeychainReadGate.withTurn { turn in
            guard case .available = turn else {
                _ = state.withLock { $0.unavailableProviderIDs.insert(providerID) }
                return
            }
            let holdFor = state.withLock {
                let isFirstPrompt = $0.promptedProviderIDs.isEmpty
                $0.active += 1
                $0.maximumActive = max($0.maximumActive, $0.active)
                $0.promptedProviderIDs.insert(providerID)
                return isFirstPrompt ? 2.2 : 0.05
            }
            Thread.sleep(forTimeInterval: holdFor)
            state.withLock { $0.active -= 1 }
        }
    }
}

@MainActor
private final class KeychainApprovalRuntime: ProviderRuntime {
    let provider: Provider
    let widgetDescriptors: [WidgetDescriptor] = []
    private let probe: ManualRefreshApprovalProbe

    init(provider: Provider, probe: ManualRefreshApprovalProbe) {
        self.provider = provider
        self.probe = probe
    }

    func refresh() async -> ProviderSnapshot {
        if ProviderRefreshContext.isManual {
            let providerID = provider.id
            let probe = probe
            await loadOffMainActor {
                probe.read(providerID: providerID)
            }
        }
        return ProviderSnapshot(providerID: provider.id, displayName: provider.displayName, lines: [])
    }
}

final class KeychainAccessorTests: XCTestCase {
    /// The SwiftPM test host is itself ad-hoc signed, so the real process-signature check would
    /// refuse every interactive read below. Pin the seam to "durable" so these tests exercise the
    /// gate's queueing/caching behavior; the refusal path is tested explicitly where it overrides
    /// this back to false.
    override func setUp() {
        super.setUp()
        InteractiveKeychainReadGate.processCanHoldDurableApprovals = { true }
    }

    override func tearDown() {
        InteractiveKeychainReadGate.processCanHoldDurableApprovals = {
            ProcessCodeSignature.canHoldDurableKeychainApprovals
        }
        super.tearDown()
    }

    func testMissingItemReadsNilAndAnUnreadableOneThrows() throws {
        // The plain throwing read must keep "no credential stored" (nil) apart from "couldn't be
        // read" (throw) — collapsing them is how a locked keychain gets mislabeled "not signed in".
        // It is also prompt-free now: this runs with no approval dialog possible.
        let accessor = SecurityKeychainAccessor()

        XCTAssertNil(try accessor.readGenericPassword(service: "RunwayTests.absent.\(UUID().uuidString)"))
    }

    func testQuietAutomaticReadReportsAMissingItemAndRestoresTheUISwitch() {
        let requestedSecretData = Locked(false)
        let blockedAuthenticationUI = Locked(false)
        let accessor = SecurityKeychainAccessor(
            coordinator: KeychainReadCoordinator(),
            copyMatching: { query, _ in
                let attributes = query as NSDictionary
                if attributes[kSecReturnData] as? Bool == true {
                    requestedSecretData.withLock { $0 = true }
                }
                return errSecItemNotFound
            },
            setUserInteractionAllowed: { allowed in
                blockedAuthenticationUI.withLock { $0 = !allowed }
                return errSecSuccess
            }
        )

        XCTAssertEqual(
            accessor.readGenericPasswordWithoutUserInteraction(service: "service"),
            .missing
        )
        XCTAssertTrue(
            requestedSecretData.withLock { $0 },
            "the quiet automatic read asks for the secret (with UI provably off)"
        )
        XCTAssertFalse(
            blockedAuthenticationUI.withLock { $0 },
            "the process-global UI switch must be restored after the quiet read"
        )
    }

    func testAutomaticReadRequestsSecretsOnlyWhileUIIsSuppressed() {
        // The automatic path may request secret data, but ONLY inside the quiet window — the
        // process-global switch off, so an approval-needing item fails errSecAuthFailed instead
        // of showing a dialog — and the switch must be restored afterwards.
        let suppressed = Locked(false)
        let unsuppressedSecretRequests = Locked(0)
        let accessor = SecurityKeychainAccessor(
            coordinator: KeychainReadCoordinator(),
            copyMatching: { query, _ in
                if (query as NSDictionary)[kSecReturnData] as? Bool == true {
                    if !suppressed.withLock({ $0 }) {
                        unsuppressedSecretRequests.withLock { $0 += 1 }
                    }
                    return errSecAuthFailed
                }
                return errSecSuccess
            },
            setUserInteractionAllowed: { allowed in
                suppressed.withLock { $0 = !allowed }
                return errSecSuccess
            }
        )

        XCTAssertEqual(
            accessor.readGenericPasswordWithoutUserInteraction(service: "service"),
            .unavailable
        )
        XCTAssertEqual(
            unsuppressedSecretRequests.withLock { $0 }, 0,
            "an automatic read may request secret data only while keychain UI is suppressed"
        )
        XCTAssertFalse(
            suppressed.withLock { $0 },
            "the process-global switch must be restored after the quiet read"
        )
    }

    func testDeferredAutomaticReadRecordsANeutralCategoryNotADenial() {
        // A quiet read that securityd answers errSecAuthFailed means "I wanted to ask and was
        // forbidden to" — the USER denied nothing. It must be remembered as `.manualReadDeferred`
        // so providers offer the neutral Connect affordance instead of a permission warning.
        let accessor = SecurityKeychainAccessor(
            coordinator: KeychainReadCoordinator(),
            copyMatching: { query, _ in
                (query as NSDictionary)[kSecReturnData] as? Bool == true ? errSecAuthFailed : errSecSuccess
            },
            setUserInteractionAllowed: { _ in errSecSuccess }
        )

        XCTAssertEqual(
            accessor.readGenericPasswordWithoutUserInteraction(service: "service"),
            .unavailable
        )
        XCTAssertEqual(accessor.lastReadFailure(service: "service"), .manualReadDeferred)
    }

    func testManualReadWaitsOutModificationDateCollisionBeforeCaching() throws {
        struct ProbeState {
            var secret = "old-secret"
            var secretReads = 0
            var waits = 0
        }

        let modificationDate = Date(timeIntervalSinceReferenceDate: 1_000)
        let clock = Locked(Date(timeIntervalSinceReferenceDate: 1_000.25))
        let state = Locked(ProbeState())
        let coordinator = KeychainReadCoordinator()
        let accessor = SecurityKeychainAccessor(
            coordinator: coordinator,
            metadataNow: { clock.withLock { $0 } },
            waitForMetadataStability: { interval in
                // Simulate another app rotating only the secret later in the same Keychain
                // modification-date second. Its metadata fingerprint remains unchanged.
                state.withLock {
                    $0.secret = "rotated-secret"
                    $0.waits += 1
                }
                clock.withLock { $0 = $0.addingTimeInterval(interval) }
            },
            copyMatching: { query, result in
                let query = query as NSDictionary
                if query[kSecReturnAttributes] as? Bool == true {
                    result?.pointee = [
                        kSecAttrService as String: "service",
                        kSecAttrAccount as String: "account",
                        kSecAttrModificationDate as String: modificationDate,
                    ] as CFDictionary
                    return errSecSuccess
                }
                if query[kSecReturnData] as? Bool == true {
                    let secret = state.withLock { value -> String in
                        value.secretReads += 1
                        return value.secret
                    }
                    result?.pointee = Data(secret.utf8) as CFData
                    return errSecSuccess
                }
                return errSecSuccess
            }
        )

        XCTAssertEqual(
            try accessor.readGenericPasswordAllowingUserInteraction(service: "service", account: "account"),
            "rotated-secret",
            "the approved read must happen after the timestamp collision window closes"
        )
        XCTAssertEqual(
            accessor.readGenericPasswordWithoutUserInteraction(service: "service", account: "account"),
            .value("rotated-secret")
        )
        XCTAssertEqual(state.withLock { $0.waits }, 1)
        XCTAssertEqual(state.withLock { $0.secretReads }, 1, "automatic reuse must not request secret data")
    }

    func testAutomaticSafeStorageReadersReadSecretsOnlyWhileUIIsSuppressed() {
        // The Safe Storage readers share the quiet-read rule: the automatic path may ask for the
        // key only inside the suppressed-UI window, an approval-needing key stays the neutral
        // deferral (never a dialog, never a denial), and the switch is restored afterwards.
        let claudeSuppressed = Locked(false)
        let claudeUnsuppressedSecretRequests = Locked(0)
        let claude = ClaudeDesktopSafeStorageKeyReader(
            coordinator: KeychainReadCoordinator(),
            copyMatching: { query, _ in
                if (query as NSDictionary)[kSecReturnData] as? Bool == true {
                    if !claudeSuppressed.withLock({ $0 }) {
                        claudeUnsuppressedSecretRequests.withLock { $0 += 1 }
                    }
                    return errSecAuthFailed
                }
                return errSecSuccess
            },
            setUserInteractionAllowed: { allowed in
                claudeSuppressed.withLock { $0 = !allowed }
                return errSecSuccess
            }
        )
        XCTAssertThrowsError(try claude.readPassword(allowInteraction: false)) {
            guard case ClaudeDesktopCredentialError.manualReadDeferred = $0 else {
                return XCTFail("expected the deferred-read outcome, got \($0)")
            }
        }
        XCTAssertEqual(claudeUnsuppressedSecretRequests.withLock { $0 }, 0)
        XCTAssertFalse(claudeSuppressed.withLock { $0 })

        let sakanaSuppressed = Locked(false)
        let sakanaUnsuppressedSecretRequests = Locked(0)
        let sakana = SakanaSafeStorageKeyReader(
            coordinator: KeychainReadCoordinator(),
            copyMatching: { query, _ in
                if (query as NSDictionary)[kSecReturnData] as? Bool == true {
                    if !sakanaSuppressed.withLock({ $0 }) {
                        sakanaUnsuppressedSecretRequests.withLock { $0 += 1 }
                    }
                    return errSecAuthFailed
                }
                return errSecSuccess
            },
            setUserInteractionAllowed: { allowed in
                sakanaSuppressed.withLock { $0 = !allowed }
                return errSecSuccess
            }
        )
        XCTAssertThrowsError(
            try sakana.readPassword(service: "Browser Safe Storage", allowInteraction: false)
        ) {
            guard case SakanaBrowserCredentialError.manualReadDeferred = $0 else {
                return XCTFail("expected the deferred-read outcome, got \($0)")
            }
        }
        XCTAssertEqual(sakanaUnsuppressedSecretRequests.withLock { $0 }, 0)
        XCTAssertFalse(sakanaSuppressed.withLock { $0 })
    }

    @MainActor
    func testManualRefreshAllQueuesThreeApprovalProvidersAndForcedAutomaticRefreshStaysPromptFree() async {
        // A manual Refresh All starts every provider at once. Whichever provider reaches the gate
        // first holds it beyond the old two-second `.peerBusy` deadline: the other two must stay
        // queued, then both receive a real turn. Then run the CLI/automatic shape (`force`, but not
        // `interactive`) and prove it makes no additional prompt-capable reads.
        let providers = ["provider-a", "provider-b", "provider-c"].map {
            Provider(id: $0, displayName: $0, icon: .providerMark("codex"))
        }
        let probe = ManualRefreshApprovalProbe()
        let runtimes = providers.map { KeychainApprovalRuntime(provider: $0, probe: probe) }
        let suiteName = "RunwayTests.keychain-refresh-all.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: providers, descriptors: []),
            providers: runtimes,
            defaults: defaults
        )

        await store.refreshAll(force: true, interactive: true)

        let afterManual = probe.state.withLock { $0 }
        XCTAssertEqual(
            afterManual.promptedProviderIDs,
            Set(providers.map(\.id)),
            "every protected provider must receive its turn in the same manual refresh"
        )
        XCTAssertTrue(afterManual.unavailableProviderIDs.isEmpty, "no provider may time out as peer-busy")
        XCTAssertEqual(afterManual.readAttempts, providers.count)
        XCTAssertEqual(afterManual.maximumActive, 1, "only one approval dialog may be open at a time")

        await store.refreshAll(force: true)

        let afterForcedNonInteractive = probe.state.withLock { $0 }
        XCTAssertEqual(afterForcedNonInteractive.promptedProviderIDs, afterManual.promptedProviderIDs)
        XCTAssertEqual(
            afterForcedNonInteractive.readAttempts,
            afterManual.readAttempts,
            "a forced automatic/CLI-style refresh must not attempt an interactive read"
        )
        XCTAssertEqual(afterForcedNonInteractive.maximumActive, 1)
    }

    func testCancelledProviderLeavesAnAbandonedDialogQueueWithoutBlockingTheNextProvider() {
        // The active Security call cannot be dismissed by cancellation, but a provider still queued
        // behind an abandoned dialog can be cancelled by its refresh watchdog. It must leave the
        // FIFO promptly, and a later provider must acquire the gate once the active dialog closes.
        let held = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let holderDone = expectation(description: "abandoned dialog released")

        let holder = Thread {
            InteractiveKeychainReadGate.withTurn { _ in
                held.signal()
                release.wait()
            }
            holderDone.fulfill()
        }
        holder.start()
        XCTAssertEqual(held.wait(timeout: .now() + 5), .success)
        var holderReleased = false
        var holderFinished = false
        defer {
            if !holderReleased { release.signal() }
            if !holderFinished { wait(for: [holderDone], timeout: 5) }
        }

        let cancelledResult = Locked<InteractiveKeychainReadGate.Turn?>(nil)
        let cancelledDone = DispatchSemaphore(value: 0)
        let queuedStarted = DispatchSemaphore(value: 0)
        let queued = Task {
            await loadOffMainActor {
                queuedStarted.signal()
                let ui = InteractiveKeychainReadGate.withTurn { $0 }
                cancelledResult.withLock { $0 = ui }
                cancelledDone.signal()
            }
        }
        XCTAssertEqual(queuedStarted.wait(timeout: .now() + 2), .success)
        Thread.sleep(forTimeInterval: 0.2)
        queued.cancel()
        XCTAssertEqual(
            cancelledDone.wait(timeout: .now() + 2),
            .success,
            "a cancelled queued provider must not remain trapped behind an abandoned dialog"
        )
        guard case .cancelled? = cancelledResult.withLock({ $0 }) else {
            return XCTFail("the cancelled provider must be told not to touch Security.framework")
        }

        let nextEntered = DispatchSemaphore(value: 0)
        let nextDone = expectation(description: "next provider completed")
        Thread {
            InteractiveKeychainReadGate.withTurn { ui in
                guard case .available = ui else { return }
                nextEntered.signal()
            }
            nextDone.fulfill()
        }.start()
        XCTAssertEqual(nextEntered.wait(timeout: .now() + 0.2), .timedOut)

        holderReleased = true
        release.signal()
        wait(for: [holderDone], timeout: 5)
        holderFinished = true
        XCTAssertEqual(nextEntered.wait(timeout: .now() + 5), .success)
        wait(for: [nextDone], timeout: 5)
    }

    func testQuietAutomaticReadLoadsAccessibleItemsAndDistinguishesMissingOnes() throws {
        let accessor = SecurityKeychainAccessor(coordinator: KeychainReadCoordinator())
        let service = "RunwayTests.keychain-ui.\(UUID().uuidString)"
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "runway-tests",
            kSecValueData as String: Data("stored-secret".utf8),
        ]
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw XCTSkip("cannot create a login-keychain item in this environment (status \(addStatus))")
        }
        defer {
            _ = SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
            ] as CFDictionary)
        }

        XCTAssertEqual(accessor.genericPasswordExists(service: service), true)
        XCTAssertEqual(
            accessor.readGenericPasswordWithoutUserInteraction(service: service),
            .value("stored-secret"),
            "an item macOS grants without UI must load on the quiet automatic path — no Connect click"
        )
        XCTAssertEqual(
            try accessor.readGenericPasswordAllowingUserInteraction(service: service),
            "stored-secret"
        )
        XCTAssertEqual(
            accessor.readGenericPasswordWithoutUserInteraction(service: "\(service).missing"),
            .missing
        )
    }

    func testChangeGatedCachePicksUpARotatedSecretOnTheNextQuietRead() throws {
        // End-to-end over a real login-keychain item: a deliberate read seeds the cache, the
        // coordinator serves it while metadata is unchanged, and a credential rotation invalidates
        // it — the next quiet automatic read then loads the replacement silently (the test host
        // created the item, so macOS grants the read without UI).
        let accessor = SecurityKeychainAccessor(coordinator: KeychainReadCoordinator())
        let service = "RunwayTests.keychain-fingerprint.\(UUID().uuidString)"
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "runway-tests",
            kSecValueData as String: Data("first-secret".utf8),
        ]
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw XCTSkip("cannot create a login-keychain item in this environment (status \(addStatus))")
        }
        defer {
            _ = SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
            ] as CFDictionary)
        }

        XCTAssertEqual(try accessor.readGenericPasswordAllowingUserInteraction(service: service), "first-secret")
        XCTAssertEqual(accessor.readGenericPasswordWithoutUserInteraction(service: service), .value("first-secret"))

        let update: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        // The label attribute changes alongside the secret, so the fingerprint must move even if the
        // modification date's resolution is coarse.
        let changes: [String: Any] = [
            kSecValueData as String: Data("second-secret".utf8),
            kSecAttrLabel as String: "rotated",
        ]
        XCTAssertEqual(SecItemUpdate(update as CFDictionary, changes as CFDictionary), errSecSuccess)

        XCTAssertEqual(
            accessor.readGenericPasswordWithoutUserInteraction(service: service),
            .value("second-secret"),
            "a rotated secret must invalidate the old cache and load fresh on the quiet automatic read"
        )
        XCTAssertEqual(try accessor.readGenericPasswordAllowingUserInteraction(service: service), "second-secret")
    }

    func testQuietTurnWaitsBehindAnotherQuietReadButSkipsBehindADialog() {
        // Behind another quiet holder (ms-scale, no UI possible) a quiet turn waits its turn —
        // otherwise the launch storm parks every gate-race loser on the Connect state for a full
        // refresh cycle. Behind a dialog-capable holder it must skip immediately: that hold is
        // unbounded, and suppressing UI there would fail the dialog the user is waiting on.
        let firstHolding = expectation(description: "first quiet turn holding")
        let release = DispatchSemaphore(value: 0)
        let firstDone = expectation(description: "first quiet turn done")
        DispatchQueue.global().async {
            let ran = InteractiveKeychainReadGate.withQuietTurn { () -> Bool in
                firstHolding.fulfill()
                release.wait()
                return true
            }
            XCTAssertEqual(ran, true)
            firstDone.fulfill()
        }
        wait(for: [firstHolding], timeout: 5)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { release.signal() }
        let second = InteractiveKeychainReadGate.withQuietTurn { true }
        XCTAssertEqual(second, true, "a quiet turn must wait out another quiet holder")
        wait(for: [firstDone], timeout: 5)

        let dialogHolding = expectation(description: "dialog turn holding")
        let dialogRelease = DispatchSemaphore(value: 0)
        let dialogDone = expectation(description: "dialog turn done")
        DispatchQueue.global().async {
            InteractiveKeychainReadGate.withTurn { _ in
                dialogHolding.fulfill()
                dialogRelease.wait()
            }
            dialogDone.fulfill()
        }
        wait(for: [dialogHolding], timeout: 5)
        XCTAssertNil(
            InteractiveKeychainReadGate.withQuietTurn { true },
            "a quiet turn must not wait behind a dialog-capable holder"
        )
        dialogRelease.signal()
        wait(for: [dialogDone], timeout: 5)
    }

    func testGateRefusesTheTurnWhenApprovalsCannotPersist() {
        // An ad-hoc build's Always Allow dies with the next rebuild, so the gate must hand the
        // refusal to the body instead of queueing a turn that would end in a pointless dialog.
        let original = InteractiveKeychainReadGate.processCanHoldDurableApprovals
        InteractiveKeychainReadGate.processCanHoldDurableApprovals = { false }
        defer { InteractiveKeychainReadGate.processCanHoldDurableApprovals = original }

        var seen: InteractiveKeychainReadGate.Turn?
        InteractiveKeychainReadGate.withTurn { turn in seen = turn }
        XCTAssertEqual(seen, .ephemeralSignature)
    }

    func testInteractiveReadFromEphemeralSignatureNeverPromptsAndStaysNeutral() {
        // The refused read must never request secret data (that request is what opens the dialog),
        // and the outcome must be remembered as the NEUTRAL deferral: the Connect affordance stays,
        // with no "access declined" warning whose Always Allow advice this build cannot honor.
        let original = InteractiveKeychainReadGate.processCanHoldDurableApprovals
        InteractiveKeychainReadGate.processCanHoldDurableApprovals = { false }
        defer { InteractiveKeychainReadGate.processCanHoldDurableApprovals = original }

        let requestedSecretData = Locked(false)
        let accessor = SecurityKeychainAccessor(
            coordinator: KeychainReadCoordinator(),
            copyMatching: { query, _ in
                if (query as NSDictionary)[kSecReturnData] as? Bool == true {
                    requestedSecretData.withLock { $0 = true }
                }
                return errSecSuccess
            }
        )

        XCTAssertThrowsError(try accessor.readGenericPasswordAllowingUserInteraction(service: "service"))
        XCTAssertFalse(
            requestedSecretData.withLock { $0 },
            "a refused turn must never request foreign secret data"
        )
        XCTAssertEqual(accessor.lastReadFailure(service: "service"), .manualReadDeferred)
    }

    func testSafeStorageReadersRefuseToPromptFromAnEphemeralSignature() {
        // The Safe Storage readers bypass the accessor, so they must apply the same refusal: no
        // Security call at all, and the deferred (connect-shaped) error, not a permission failure.
        let original = InteractiveKeychainReadGate.processCanHoldDurableApprovals
        InteractiveKeychainReadGate.processCanHoldDurableApprovals = { false }
        defer { InteractiveKeychainReadGate.processCanHoldDurableApprovals = original }

        let touchedKeychain = Locked(false)
        let touch: @Sendable (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = { _, _ in
            touchedKeychain.withLock { $0 = true }
            return errSecSuccess
        }

        let claude = ClaudeDesktopSafeStorageKeyReader(
            coordinator: KeychainReadCoordinator(),
            copyMatching: touch
        )
        XCTAssertThrowsError(try claude.readPassword(allowInteraction: true)) {
            guard case ClaudeDesktopCredentialError.manualReadDeferred = $0 else {
                return XCTFail("expected the deferred-read outcome, got \($0)")
            }
        }

        let sakana = SakanaSafeStorageKeyReader(
            coordinator: KeychainReadCoordinator(),
            copyMatching: touch
        )
        XCTAssertThrowsError(try sakana.readPassword(service: "Chrome Safe Storage", allowInteraction: true)) {
            guard case SakanaBrowserCredentialError.manualReadDeferred = $0 else {
                return XCTFail("expected the deferred-read outcome, got \($0)")
            }
        }

        XCTAssertFalse(touchedKeychain.withLock { $0 }, "a refused turn must never reach Security.framework")
    }

    func testRunwayOwnedStoreRoundTripsAndUpdatesPrivateFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunwayOwnedFileStoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RunwayOwnedFileStore(directory: directory.path)
        let service = "RunwayTests.owned.\(UUID().uuidString)"

        XCTAssertNil(try store.read(service: service))
        try store.write(service: service, value: "first-value")
        XCTAssertEqual(try store.read(service: service), "first-value")

        try store.write(service: service, value: "second-value")
        XCTAssertEqual(try store.read(service: service), "second-value")

        let attributes = try FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent(service).path
        )
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

}
