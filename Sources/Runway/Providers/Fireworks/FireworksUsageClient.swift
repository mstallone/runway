import Foundation

struct FireworksUsageClient: Sendable {
    static let baseURL = "https://api.fireworks.ai/v1"

    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    /// The accounts the key can see. Used only when `auth.ini` names no account; two is enough to
    /// tell "exactly one" from "several".
    func fetchAccounts(apiKey: String) async throws -> HTTPResponse {
        try await get("\(Self.baseURL)/accounts?pageSize=2", apiKey: apiKey)
    }

    /// Every quota on the account. The monthly spend limit is one of them (`monthly-spend-usd`).
    func fetchQuotas(apiKey: String, accountID: String) async throws -> HTTPResponse {
        guard let encoded = accountID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw FireworksUsageError.invalidResponse
        }
        return try await get("\(Self.baseURL)/accounts/\(encoded)/quotas?pageSize=200", apiKey: apiKey)
    }

    private func get(_ urlString: String, apiKey: String) async throws -> HTTPResponse {
        guard let url = URL(string: urlString) else {
            throw FireworksUsageError.invalidResponse
        }

        return try await http.send(HTTPRequest(
            method: "GET",
            url: url,
            headers: [
                "Authorization": "Bearer \(apiKey)",
                "Accept": "application/json"
            ],
            timeout: 15
        ))
    }
}

enum FireworksUsageError: Error, LocalizedError, Equatable {
    case connectionFailed
    case invalidResponse
    case requestFailed(Int)
    /// The account has no `monthly-spend-usd` quota (some enterprise accounts are uncapped).
    case monthlySpendUnavailable

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return "Couldn't reach Fireworks. Check your connection."
        case .invalidResponse:
            return "Fireworks usage data unavailable. Try again later."
        case .requestFailed(let status):
            return "Fireworks request failed (HTTP \(status))."
        case .monthlySpendUnavailable:
            return "Fireworks reports no monthly spend limit for this account."
        }
    }
}
