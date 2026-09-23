import Foundation

struct MuseUsageClient: Sendable {
    static let usageURL = URL(string: "https://dev.meta.ai/usage/")!
    var http: any HTTPClient

    init(http: any HTTPClient = MusePortalHTTPClient()) {
        self.http = http
    }

    static let teamsURL = URL(string: "https://dev.meta.ai/api/portal/teams")!

    /// The current dashboard calls this JSON API with its browser session. No key mint or inference.
    func fetchUsage(sessionToken: String) async throws -> HTTPResponse {
        let teamsResponse = try await get(Self.teamsURL, sessionToken: sessionToken)
        guard (200..<300).contains(teamsResponse.statusCode) else { return teamsResponse }
        guard let object = ProviderParse.jsonObject(teamsResponse.body),
              let teams = object["teams"] as? [[String: Any]]
        else { throw MuseUsageError.invalidResponse }
        for team in teams {
            guard let id = team["team_id"] as? String, !id.isEmpty,
                  id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                      || (97...122).contains($0) || $0 == 45 || $0 == 95 })
            else { throw MuseUsageError.invalidResponse }
            let url = Self.teamsURL.appendingPathComponent(id).appendingPathComponent("subscription-quota")
            let response = try await get(url, sessionToken: sessionToken)
            guard (200..<300).contains(response.statusCode) else { return response }
            guard let object = ProviderParse.jsonObject(response.body) else { throw MuseUsageError.invalidResponse }
            guard let quota = object["subscription_quota"] else { throw MuseUsageError.invalidResponse }
            if quota is NSNull { continue }
            return response
        }
        throw MuseUsageError.quotaUnavailable
    }

    private func get(_ url: URL, sessionToken: String) async throws -> HTTPResponse {
        do {
            return try await http.send(HTTPRequest(
                method: "GET", url: url,
                headers: ["Cookie": "\(MuseAuthStore.cookieName)=\(sessionToken)",
                          "Accept": "application/json", "Content-Type": "application/json"],
                timeout: 20
            ))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MuseUsageError.connectionFailed
        }
    }
}

/// Use no shared cookie jar or disk cache, and never forward the cookie through a redirect.
struct MusePortalHTTPClient: HTTPClient {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        if let proxy = ProxyConfig.current {
            configuration.proxyConfigurations = [proxy.proxyConfiguration()]
        }
        let session = URLSession(configuration: configuration, delegate: MusePortalRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method
        for (key, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await session.data(for: urlRequest)
        guard let response = response as? HTTPURLResponse else { throw HTTPClientError.invalidResponse }
        let headers = Dictionary(response.allHeaderFields.map {
            (String(describing: $0.key).lowercased(), String(describing: $0.value))
        }, uniquingKeysWith: { _, last in last })
        AppLog.debug(.http, "Muse portal GET -> \(response.statusCode)")
        return HTTPResponse(statusCode: response.statusCode, headers: headers, body: data)
    }
}

final class MusePortalRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

enum MuseUsageError: Error, LocalizedError, Equatable {
    case connectionFailed, invalidResponse, quotaUnavailable
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .connectionFailed: return ProviderUsageErrorText.connectionFailed
        case .invalidResponse: return "Muse dashboard usage couldn't be read. Open dev.meta.ai/usage/ and try again later."
        case .quotaUnavailable: return "No Muse subscription quota is available on this dashboard. Check your account at dev.meta.ai/usage/."
        case .requestFailed(let status): return ProviderUsageErrorText.requestFailed(statusCode: status)
        }
    }
}
