import Foundation

struct MuseUsageClient: Sendable {
    static let keyURL = URL(string: "https://api.meta.ai/muse-code/key")!
    /// Muse Code's mint client labels itself with Meta's surface header. The same header is required
    /// for `/muse-code/key`; `tbh:tui` is the CLI's value for this call.
    static let clientSurface = "tbh:tui"

    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    /// Muse Code subscription meters, returned as a side effect of minting a Model API key. Callers
    /// must not persist that key — Runway reads `subs_usage` only. This is not a poll-safe usage
    /// endpoint; the provider backs off when Meta rate-limits it.
    func fetchKey(accessToken: String) async throws -> HTTPResponse {
        do {
            return try await http.send(HTTPRequest(
                method: "POST",
                url: Self.keyURL,
                headers: [
                    "Authorization": "Bearer \(accessToken)",
                    "Accept": "application/json",
                    "Content-Type": "application/json",
                    "User-Agent": "Runway",
                    "x-api-version": "1.0.0",
                    "x-client-id": Self.clientSurface
                ],
                body: Data("{}".utf8),
                timeout: 8
            ))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MuseUsageError.connectionFailed
        }
    }
}

enum MuseUsageError: Error, LocalizedError, Equatable {
    case connectionFailed
    case invalidResponse
    case requestFailed(Int)
    /// The Meta login is valid but the account has no active Muse Code subscription.
    case noSubscription

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return ProviderUsageErrorText.connectionFailed
        case .invalidResponse:
            return ProviderUsageErrorText.invalidResponse
        case .requestFailed(let status):
            return ProviderUsageErrorText.requestFailed(statusCode: status)
        case .noSubscription:
            return "No active Muse Code subscription. Subscribe at accountscenter.meta.com/muse_code to see usage."
        }
    }
}
