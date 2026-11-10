import Foundation

struct FireworksAuth: Hashable, Sendable {
    var apiKey: String
    /// The account named next to the key in `auth.ini`. `nil` means it is discovered from the API.
    var accountID: String?
}

enum FireworksAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn
    /// The Nexus CLI's Keychain item exists but hasn't been loaded this process — the neutral
    /// connect prompt, not a warning.
    case keychainConnectRequired
    /// An attempted manual read of the Nexus CLI's Keychain item was denied.
    case keychainPermissionRequired
    /// `~/.fireworks/auth.ini` exists but couldn't be read, or the Keychain item couldn't be
    /// inspected (locked keychain), and no other login stood in for it.
    case credentialStoreUnreadable
    case invalidKey
    /// The key sees zero or several accounts and `auth.ini` names none, so the right one can't be
    /// picked.
    case accountUnknown

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Not logged in. Run `firectl set-api-key` or `nexus login`."
        case .keychainConnectRequired:
            return "Fireworks login found in Keychain. Connect to load it; if macOS asks, choose Always Allow to avoid future dialogs."
        case .keychainPermissionRequired:
            return "Keychain access to the Fireworks login was declined. Refresh and choose Always Allow when macOS asks."
        case .credentialStoreUnreadable:
            return "Fireworks login couldn’t be read. Check ~/.fireworks/auth.ini, unlock your login keychain, and refresh."
        case .invalidKey:
            return "Fireworks API key was rejected. Run `firectl set-api-key` or `nexus login` again."
        case .accountUnknown:
            return "Fireworks account is unknown. Add `account_id` to ~/.fireworks/auth.ini."
        }
    }
}

/// Outcome of a credential load. `connectRequired` means the Nexus Keychain item exists but its
/// secret hasn't been loaded into this process yet — a real login that only an explicit user action
/// may convert into access.
enum FireworksCredentialLoad: Equatable, Sendable {
    case auth(FireworksAuth)
    case connectRequired
    case keychainPermissionRequired
    case unreadable
    case none
}

/// Reads the Fireworks API key the user's own CLI already stored: `firectl set-api-key` writes
/// `~/.fireworks/auth.ini` (key plus account), and the Nexus CLI's `nexus login` writes only the key
/// to the Keychain. Runway never asks for a key.
struct FireworksAuthStore: Sendable {
    static let authPath = "~/.fireworks/auth.ini"
    /// Keychain service the Fireworks Nexus CLI (`nexus login`) writes to.
    static let nexusKeychainService = "FireworksAI"

    var files: TextFileAccessing
    var keychain: KeychainReading

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        keychain: KeychainReading = SecurityKeychainAccessor()
    ) {
        self.files = files
        self.keychain = keychain
    }

    /// `firectl` first, because it also names the account; then the Nexus Keychain item. Automatic
    /// refreshes never prompt: only a manual refresh may ask macOS to read the Keychain item.
    func loadCredentials(allowKeychainInteraction: Bool = false) -> FireworksCredentialLoad {
        let file = loadFirectlAuth()
        if case .auth = file { return file }

        let keychainLoad = loadNexusAuth(allowInteraction: allowKeychainInteraction)
        if case .none = keychainLoad { return file }
        return keychainLoad
    }

    private func loadFirectlAuth() -> FireworksCredentialLoad {
        guard files.exists(Self.authPath) else { return .none }
        let text: String
        do {
            guard let read = try files.readTextIfPresent(Self.authPath) else { return .none }
            text = read
        } catch {
            AppLog.warn(LogTag.auth("fireworks"), "couldn't read \(Self.authPath): \(error.localizedDescription)")
            return .unreadable
        }
        let values = Self.parseINI(text)
        guard let apiKey = values["api_key"] else { return .none }
        let accountID = values["account_id"].map(Self.normalizedAccountID).flatMap { $0.isEmpty ? nil : $0 }
        return .auth(FireworksAuth(apiKey: apiKey, accountID: accountID))
    }

    private func loadNexusAuth(allowInteraction: Bool) -> FireworksCredentialLoad {
        let read: NonInteractiveKeychainRead
        if allowInteraction {
            do {
                read = try keychain.readGenericPasswordAllowingUserInteraction(service: Self.nexusKeychainService)
                    .map(NonInteractiveKeychainRead.value) ?? .missing
            } catch {
                read = .unavailable
            }
        } else {
            read = keychain.readGenericPasswordWithoutUserInteraction(service: Self.nexusKeychainService)
        }

        switch read {
        case .value(let raw):
            let apiKey = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return apiKey.isEmpty ? .none : .auth(FireworksAuth(apiKey: apiKey, accountID: nil))
        case .missing:
            return .none
        case .unavailable:
            switch keychain.lastReadFailure(service: Self.nexusKeychainService) {
            case .manualReadDeferred?: return .connectRequired
            case .permissionDenied?: return .keychainPermissionRequired
            case .unreadable?: return .unreadable
            case nil:
                // No verdict recorded: a confirmed-present item was simply never read (a deferral),
                // an unexamined one reports unreadable, and only a confirmed absence is no login.
                switch keychain.genericPasswordExists(service: Self.nexusKeychainService) {
                case true?: return .connectRequired
                case nil: return .unreadable
                case false?: return .none
                }
            }
        }
    }

    /// Reads the `key = value` lines `firectl` writes, with or without section headers. Keys are
    /// lowercased with `-` folded to `_`; the first non-empty value for each key wins.
    static func parseINI(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix(";"), !line.hasPrefix("["),
                  let separator = line.firstIndex(where: { $0 == "=" || $0 == ":" })
            else {
                continue
            }
            let key = line[..<separator]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
                .replacingOccurrences(of: "-", with: "_")
            var value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let quote = value.first, quote == "\"" || quote == "'", value.last == quote {
                value = String(value.dropFirst().dropLast())
            }
            guard !value.isEmpty, values[key] == nil else { continue }
            values[key] = value
        }
        return values
    }

    /// Accepts both `acme` and the resource name `accounts/acme`.
    static func normalizedAccountID(_ value: String) -> String {
        var id = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.hasPrefix("accounts/") {
            id.removeFirst("accounts/".count)
        }
        return id.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
