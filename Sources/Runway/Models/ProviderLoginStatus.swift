/// Classify provider failures before they become display strings. Network failures and quota
/// warnings must not make a valid login appear disconnected.
enum ProviderLoginStatus {
    /// No error verifies the login; an unrelated failure leaves its status unknown.
    static func requirement(after error: Error?) -> Bool? {
        guard let error else { return false }
        return requiresLogin(error) ? true : nil
    }

    static func requiresLogin(_ error: Error) -> Bool {
        switch error {
        case is DevinAuthError, is MuseAuthError, is CopilotAuthError, is CursorAuthError,
             is CodexAuthError, is SakanaAuthError, is GrokAuthError:
            return true
        case let error as ClaudeAuthError:
            if case .invalidOAuthURL = error { return false }
            return true
        case let error as KimiAuthError:
            switch error {
            case .notLoggedIn, .credentialsUnreadable, .invalidCredentials, .sessionExpired: return true
            default: return false
            }
        case let error as OpenRouterAuthError:
            return error == .missingKey || error == .invalidKey
        case let error as ZAIAuthError:
            return error == .missingKey || error == .invalidKey
        case let error as AntigravityError:
            return error != .unavailable
        case let error as OpenCodeUsageError:
            switch error {
            case .notLoggedIn, .credentialsUnreadable, .unauthorized: return true
            default: return false
            }
        default:
            return false
        }
    }
}
