import Foundation

struct MuseUsageClient: Sendable {
    static let usageURL = URL(string: "https://dev.meta.ai/usage/")!
    var http: any HTTPClient

    init(http: any HTTPClient = MuseDashboardHTTPClient()) {
        self.http = http
    }

    /// Read the dashboard's embedded quota; never mint a key or generate a model response.
    func fetchUsage(sessionToken: String) async throws -> HTTPResponse {
        do {
            return try await http.send(HTTPRequest(
                method: "GET", url: Self.usageURL,
                headers: ["Cookie": "\(MuseAuthStore.cookieName)=\(sessionToken)", "Accept": "text/html"],
                timeout: 20
            ))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MuseUsageError.connectionFailed
        }
    }
}

/// Dashboard redirects select the team/project on the same host. A login redirect is returned
/// to the provider, including redirects to the public homepage. No shared
/// URLSession cookie jar or disk cache can substitute another account's session or quota.
struct MuseDashboardHTTPClient: HTTPClient {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        if let proxy = ProxyConfig.current {
            configuration.proxyConfigurations = [proxy.proxyConfiguration()]
        }
        let session = URLSession(configuration: configuration, delegate: MuseDashboardRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method
        for (key, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await session.data(for: urlRequest)
        guard let response = response as? HTTPURLResponse else { throw HTTPClientError.invalidResponse }
        let headers = Dictionary(response.allHeaderFields.map {
            (String(describing: $0.key).lowercased(), String(describing: $0.value))
        }, uniquingKeysWith: { _, last in last })
        AppLog.debug(.http, "Muse dashboard GET -> \(response.statusCode)")
        return HTTPResponse(statusCode: response.statusCode, headers: headers, body: data)
    }
}

final class MuseDashboardRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    static func request(_ proposed: URLRequest, original: URLRequest?) -> URLRequest? {
        guard let url = proposed.url,
              url.scheme == "https", url.host == "dev.meta.ai",
              url.path == "/usage" || url.path == "/usage/",
              url.port == nil || url.port == 443, url.user == nil, url.password == nil
        else { return nil }
        var request = proposed
        request.setValue(original?.value(forHTTPHeaderField: "Cookie"), forHTTPHeaderField: "Cookie")
        return request
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(Self.request(request, original: task.originalRequest))
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
