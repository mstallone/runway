import Foundation

/// OAuth access token the Muse Code CLI already stored on this Mac.
struct MuseAuth: Hashable, Sendable {
    var accessToken: String
}

/// Outcome of a credential load. `connectRequired` means the Keychain item exists but its secret
/// hasn't been loaded this process — a real login footprint that only an explicit user action may
/// convert into access.
enum MuseCredentialLoad: Equatable, Sendable {
    case token(MuseAuth)
    case connectRequired
    case keychainPermissionRequired
    case unreadable
    case invalid
    case none

    var token: MuseAuth? {
        guard case .token(let auth) = self else { return nil }
        return auth
    }
}

enum MuseAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn
    case invalidCredentialData
    case sessionExpired
    /// The Keychain item is present but automatic refresh has no fresh manually loaded value —
    /// the neutral connect prompt.
    case keychainConnectRequired
    /// An attempted (user-attended) read of the Keychain item was denied.
    case keychainPermissionRequired
    case credentialStoreUnreadable

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Not logged in to Muse Code. Run `muse login` and try again."
        case .invalidCredentialData:
            return "Muse credentials are invalid. Run `muse login` again."
        case .sessionExpired:
            return "Muse session expired. Run `muse login` again."
        case .keychainConnectRequired:
            return "Muse login found in Keychain. Connect to load it; if macOS asks, choose Always Allow to avoid future dialogs."
        case .keychainPermissionRequired:
            return "Keychain access to the Muse login was declined. Refresh and choose Always Allow when macOS asks."
        case .credentialStoreUnreadable:
            return "Couldn't read Muse credentials from Keychain. Unlock Keychain or run `muse login` again."
        }
    }
}

/// Reads the Meta account login Muse Code already left on the machine. Current CLI builds store
/// the OAuth access token in the macOS Keychain (service `ai.meta.dev.credentials`, account `meta`).
/// Older builds also wrote `access_token` into `auth.json`; that file is a fallback only.
///
/// A `META_API_KEY` pay-as-you-go key is not a subscription login and is never treated as one.
/// Runway never writes this Keychain item and never persists the API key snapshot `/muse-code/key`
/// returns.
struct MuseAuthStore: Sendable {
    static let keychainService = "ai.meta.dev.credentials"
    static let keychainAccount = "meta"
    static let defaultAuthPath = "~/.config/muse/auth.json"

    var keychain: KeychainReading
    var files: TextFileAccessing
    var environment: EnvironmentReading

    init(
        keychain: KeychainReading = SecurityKeychainAccessor(),
        files: TextFileAccessing = LocalTextFileAccessor(),
        environment: EnvironmentReading = ProcessEnvironmentReader()
    ) {
        self.keychain = keychain
        self.files = files
        self.environment = environment
    }

    /// Blocking (Keychain / file) — call off the main actor.
    /// `allowKeychainInteraction` is true only for a manual refresh: that read may raise the macOS
    /// approval prompt once, for Runway itself; automatic refreshes and launch detection never prompt.
    func loadCredentials(allowKeychainInteraction: Bool = false) -> MuseCredentialLoad {
        let keychainLoad = loadFromKeychain(allowKeychainInteraction: allowKeychainInteraction)
        switch keychainLoad {
        case .none:
            return loadFromAuthFile()
        case .token, .connectRequired, .keychainPermissionRequired, .unreadable, .invalid:
            return keychainLoad
        }
    }

    func hasCredentialFootprint() -> Bool {
        loadCredentials() != .none
    }

    func authFilePath() -> String {
        if let override = environment.value(for: "MUSE_AUTH_PATH")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        {
            return override
        }
        if let xdg = environment.value(for: "XDG_CONFIG_HOME")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        {
            return "\(xdg.trimmingTrailingSlashes)/muse/auth.json"
        }
        return Self.defaultAuthPath
    }

    // MARK: - Keychain

    private func loadFromKeychain(allowKeychainInteraction: Bool) -> MuseCredentialLoad {
        guard allowKeychainInteraction else {
            switch keychain.readGenericPasswordWithoutUserInteraction(
                service: Self.keychainService,
                account: Self.keychainAccount
            ) {
            case .value(let raw):
                return credentialLoad(fromKeychainRaw: raw)
            case .missing:
                return .none
            case .unavailable:
                switch keychain.lastReadFailure(
                    service: Self.keychainService,
                    account: Self.keychainAccount
                ) {
                case .manualReadDeferred?:
                    AppLog.info(LogTag.auth("muse"), "keychain secret not loaded this process; a manual read can load it")
                    return .connectRequired
                case .permissionDenied?:
                    AppLog.error(LogTag.auth("muse"), "keychain approval was not granted; refresh manually to approve access")
                    return .keychainPermissionRequired
                case .unreadable?:
                    AppLog.error(LogTag.auth("muse"), "keychain credential could not be read; the keychain may be locked")
                    return .unreadable
                case nil:
                    switch keychain.genericPasswordExists(
                        service: Self.keychainService,
                        account: Self.keychainAccount
                    ) {
                    case true?:
                        AppLog.info(LogTag.auth("muse"), "keychain secret not loaded this process; a manual read can load it")
                        return .connectRequired
                    case nil:
                        AppLog.error(LogTag.auth("muse"), "keychain credential could not be read; the keychain may be locked")
                        return .unreadable
                    case false?:
                        return .none
                    }
                }
            }
        }

        do {
            guard let raw = try keychain.readGenericPasswordAllowingUserInteraction(
                service: Self.keychainService,
                account: Self.keychainAccount
            ) else {
                return .none
            }
            return credentialLoad(fromKeychainRaw: raw)
        } catch {
            switch keychain.lastReadFailure(
                service: Self.keychainService,
                account: Self.keychainAccount
            ) {
            case .permissionDenied?:
                AppLog.error(LogTag.auth("muse"), "keychain approval was not granted; refresh manually to approve access")
                return .keychainPermissionRequired
            case .manualReadDeferred?:
                AppLog.info(LogTag.auth("muse"), "keychain secret not loaded this process; a manual read can load it")
                return .connectRequired
            case .unreadable?, nil:
                AppLog.error(LogTag.auth("muse"), "keychain credential could not be read; the keychain may be locked")
                return .unreadable
            }
        }
    }

    private func credentialLoad(fromKeychainRaw raw: String) -> MuseCredentialLoad {
        guard let text = ProviderParse.unwrapGoKeyring(raw),
              let token = Self.accessToken(fromCredentialText: text)
        else {
            AppLog.error(LogTag.auth("muse"), "keychain credential is malformed or has no access token")
            return .invalid
        }
        return .token(MuseAuth(accessToken: token))
    }

    // MARK: - Auth file (legacy)

    private func loadFromAuthFile() -> MuseCredentialLoad {
        let path = authFilePath()
        let text: String
        do {
            guard let stored = try files.readTextIfPresent(path) else { return .none }
            text = stored
        } catch {
            AppLog.error(LogTag.auth("muse"), "auth file could not be read")
            return .unreadable
        }
        switch Self.parseAuthFile(text) {
        case .token(let token):
            return .token(MuseAuth(accessToken: token))
        case .pointerOnly:
            return .none
        case .malformed:
            AppLog.error(LogTag.auth("muse"), "auth file is malformed")
            return .invalid
        }
    }

    enum AuthFileParse: Equatable {
        case token(String)
        case pointerOnly
        case malformed
    }

    /// Current CLI `auth.json` is a pointer (`storage: keychain`) with no secret. Older files
    /// still carry `access_token` at the root or under `providers.meta`.
    static func parseAuthFile(_ text: String) -> AuthFileParse {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            return .malformed
        }
        if let token = accessToken(fromObject: object) {
            return .token(token)
        }
        return .pointerOnly
    }

    static func accessToken(fromCredentialText text: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            return nil
        }
        return accessToken(fromObject: object)
    }

    private static func accessToken(fromObject object: [String: Any]) -> String? {
        if let token = firstString(object, ["access_token", "accessToken"]) {
            return token
        }
        for key in ["providers", "oauth", "token", "credentials", "auth"] {
            guard let nested = object[key] as? [String: Any] else { continue }
            if key == "providers" {
                if let meta = nested["meta"] as? [String: Any],
                   let token = accessToken(fromObject: meta) {
                    return token
                }
                continue
            }
            if let token = accessToken(fromObject: nested) {
                return token
            }
        }
        return nil
    }

    private static func firstString(_ object: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            if let value = (object[key] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
            {
                return value
            }
        }
        return nil
    }
}
