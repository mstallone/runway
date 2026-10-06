import Foundation

enum ClaudeUsageError: Error, LocalizedError, Equatable {
    case connectionFailed
    case invalidResponse
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return ProviderUsageErrorText.connectionFailed
        case .invalidResponse:
            return ProviderUsageErrorText.invalidResponse
        case .requestFailed(let statusCode):
            return ProviderUsageErrorText.requestFailed(statusCode: statusCode)
        }
    }
}

/// Read-only client for Claude's usage endpoint. Token rotation lives elsewhere and under strict
/// guards (`ClaudeTokenRenewal`): a second process refreshing a still-valid token can trip the
/// server's reuse detection, so only an already-expired token is ever renewed, and the rotated
/// credential is always written back to Claude Code's own store.
struct ClaudeUsageClient: Sendable {
    var httpClient: HTTPClient

    init(httpClient: HTTPClient = URLSessionHTTPClient()) {
        self.httpClient = httpClient
    }

    /// `GET /api/oauth/usage?cedar_ember=1`. The flag opts in to the `cedar_ember` block (Anthropic's
    /// one-off usage-limit reset grants, the Rate Limit Resets row), which the endpoint returns as
    /// `null` without it. The User-Agent follows Claude Code's own `claude-cli/<version> (external, cli)`
    /// format: Anthropic decides grant eligibility by client surface, and a string it doesn't recognize
    /// as Claude Code comes back `eligible: false, ineligible_reason: "surface"` with no grants.
    func fetchUsage(accessToken: String, usageURL: URL) async throws -> HTTPResponse {
        try await httpClient.send(
            HTTPRequest(
                method: "GET",
                url: Self.usageURLWithResetGrants(usageURL),
                headers: [
                    "Authorization": "Bearer \(accessToken.trimmingCharacters(in: .whitespacesAndNewlines))",
                    "Accept": "application/json",
                    "Content-Type": "application/json",
                    "anthropic-beta": "oauth-2025-04-20",
                    "User-Agent": "claude-cli/2.1.280 (external, cli)"
                ],
                timeout: 10
            )
        )
    }

    static func usageURLWithResetGrants(_ usageURL: URL) -> URL {
        guard var components = URLComponents(url: usageURL, resolvingAgainstBaseURL: false) else { return usageURL }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "cedar_ember", value: "1")]
        return components.url ?? usageURL
    }
}
