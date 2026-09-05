import Foundation

struct MuseUsageClient: Sendable {
    static let keyURL = URL(string: "https://api.meta.ai/muse-code/key")!

    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    /// Muse Code subscription meters. The JSON also snapshots an API key; callers must not persist
    /// that field — Runway reads `subs_usage` only.
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
                    "x-api-version": "1.0.0"
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
