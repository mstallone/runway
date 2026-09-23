import Foundation

/// Reuses Runway's Chromium cookie reader and coordinated Safe Storage access. Muse CLI
/// credentials are deliberately not consulted: subscription reads use the dashboard session.
struct MuseAuthStore: Sendable {
    static let cookieName = "llm_sess"
    static let cookieHosts = ["dev.meta.ai", ".dev.meta.ai", "meta.ai", ".meta.ai"]

    private let browser: SakanaAuthStore

    init(
        sqlite: any SQLiteAccessing = SQLiteCLIAccessor(),
        files: any TextFileAccessing = LocalTextFileAccessor(),
        keyReader: any SakanaSafeStorageKeyReading = SakanaSafeStorageKeyReader(),
        sources: (@Sendable () -> [SakanaBrowserCookieSource])? = nil,
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser }
    ) {
        browser = SakanaAuthStore(
            sqlite: sqlite, files: files, keyReader: keyReader, sources: sources,
            homeDirectory: homeDirectory,
            cookieName: Self.cookieName, cookieHosts: Self.cookieHosts, providerID: "muse"
        )
    }

    func hasCredentialFootprint() -> Bool {
        browser.hasBrowserSessionFootprint()
    }

    func loadSession(allowInteraction: Bool) throws -> SakanaBrowserSession {
        do {
            return try browser.loadSession(allowInteraction: allowInteraction)
        } catch let error as SakanaAuthError {
            switch error {
            case .notLoggedIn: throw MuseAuthError.notLoggedIn
            case .connectRequired: throw MuseAuthError.keychainConnectRequired
            case .permissionRequired: throw MuseAuthError.keychainPermissionRequired
            case .credentialsUnreadable: throw MuseAuthError.credentialStoreUnreadable
            case .invalidCookie: throw MuseAuthError.invalidCredentialData
            case .sessionExpired: throw MuseAuthError.sessionExpired
            }
        }
    }
}

enum MuseAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn, invalidCredentialData, sessionExpired
    case keychainConnectRequired, keychainPermissionRequired, credentialStoreUnreadable

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Sign in to dev.meta.ai in Chrome, Arc, Brave, or Edge to see Muse subscription usage."
        case .invalidCredentialData:
            return "The Meta browser session couldn't be decoded. Sign in to dev.meta.ai again, then refresh."
        case .sessionExpired:
            return "The Meta browser session expired. Sign in to dev.meta.ai again, then refresh."
        case .keychainConnectRequired:
            return "Meta browser session found. Connect to read it; if macOS asks, allow access to your browser's Safe Storage key."
        case .keychainPermissionRequired:
            return "Access to your browser's Safe Storage key was declined. Refresh to connect again."
        case .credentialStoreUnreadable:
            return "Couldn't read the Meta browser session. Open dev.meta.ai in a supported browser and refresh again."
        }
    }
}
