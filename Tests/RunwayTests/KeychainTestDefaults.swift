import Foundation
@testable import Runway

/// Test-target-only defaults so keychain doubles only implement the reads a test cares about. The app
/// target has none on purpose: the real accessor must implement every mode itself (metadata-only,
/// prompt-free, and prompt-capable paths differ), not inherit a fallback that reads the secret.
extension KeychainReading {
    func readGenericPasswordForCurrentUser(service: String) throws -> String? {
        try readGenericPassword(service: service)
    }

    func readGenericPasswordAllowingUserInteraction(service: String) throws -> String? {
        try readGenericPassword(service: service)
    }

    func readGenericPasswordForCurrentUserAllowingUserInteraction(service: String) throws -> String? {
        try readGenericPasswordForCurrentUser(service: service)
    }

    func readGenericPasswordWithoutUserInteraction(service: String) -> NonInteractiveKeychainRead {
        do {
            return try readGenericPassword(service: service).map(NonInteractiveKeychainRead.value) ?? .missing
        } catch {
            return .unavailable
        }
    }

    func readGenericPasswordForCurrentUserWithoutUserInteraction(service: String) -> NonInteractiveKeychainRead {
        do {
            return try readGenericPasswordForCurrentUser(service: service)
                .map(NonInteractiveKeychainRead.value) ?? .missing
        } catch {
            return .unavailable
        }
    }

    /// Default for mocks that don't model accounts: fall back to the service-only lookup. The real
    /// `SecurityKeychainAccessor` overrides this to pass `-a <account>`.
    func readGenericPassword(service: String, account: String) throws -> String? {
        try readGenericPassword(service: service)
    }

    /// Defaults for mocks: route the account-scoped modes through the plain account read, mirroring
    /// the service-only defaults above. Production overrides these with metadata/cache-only and
    /// prompt-capable in-process paths.
    func readGenericPasswordWithoutUserInteraction(service: String, account: String) -> NonInteractiveKeychainRead {
        do {
            return try readGenericPassword(service: service, account: account)
                .map(NonInteractiveKeychainRead.value) ?? .missing
        } catch {
            return .unavailable
        }
    }

    func readGenericPasswordAllowingUserInteraction(service: String, account: String) throws -> String? {
        try readGenericPassword(service: service, account: account)
    }

    /// Whether an item exists for `service`, without reading its secret. `nil` means the probe
    /// itself failed (locked keychain, denied) — the caller picks its own safe side, which is not
    /// the same for every caller. The default (for mocks) falls back to a read; the real
    /// `SecurityKeychainAccessor` overrides this with an in-process attributes-only probe that does
    /// not evaluate the item's secret ACL.
    func genericPasswordExists(service: String) -> Bool? {
        do {
            return try readGenericPassword(service: service) != nil
        } catch {
            return nil
        }
    }

    func genericPasswordExists(service: String, account: String) -> Bool? {
        do {
            return try readGenericPassword(service: service, account: account) != nil
        } catch {
            return nil
        }
    }

    func genericPasswordForCurrentUserExists(service: String) -> Bool? {
        genericPasswordExists(service: service)
    }

    func lastReadFailure(service: String, account: String) -> KeychainReadFailure? {
        nil
    }

    func lastReadFailure(service: String) -> KeychainReadFailure? {
        nil
    }

    func lastReadFailureForCurrentUser(service: String) -> KeychainReadFailure? {
        nil
    }

    func genericPasswordAttributeFingerprint(service: String, account: String) -> String? {
        nil
    }
}
