import Foundation
import Network

/// Optional proxy routing for provider HTTP requests, as documented in docs/proxy.md:
/// `~/.runway/config.json` containing
/// `{"proxy": {"enabled": true, "url": "socks5://127.0.0.1:10808"}}`.
///
/// Loaded once at startup; restart the app after editing the file. Missing, disabled, invalid, or
/// unreadable config leaves proxying off. Credentials may be embedded in the URL
/// (`http://user:pass@host:port`). Loopback hosts always bypass the proxy.
struct ProxyConfig: Equatable, Sendable {
    enum Scheme: String, Equatable, Sendable {
        case socks5
        case http
        case https

        var defaultPort: UInt16 {
            switch self {
            case .socks5: return 1080
            case .http: return 80
            case .https: return 443
            }
        }
    }

    var scheme: Scheme
    var host: String
    var port: UInt16
    var username: String?
    var password: String?

    static let configPath = "~/.runway/config.json"

    /// The app-wide proxy, read from disk exactly once (first use).
    static let current: ProxyConfig? = load(text: readConfigText())

    /// The config file's text. A missing file is the normal case and stays silent; one that exists
    /// but can't be read is logged, because the user's traffic then goes direct.
    private static func readConfigText() -> String? {
        do {
            return try String(contentsOfFile: NSString(string: configPath).expandingTildeInPath, encoding: .utf8)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch {
            AppLog.warn(.config, "proxy off: couldn't read \(configPath): \(error.localizedDescription)")
            return nil
        }
    }

    /// Parses config-file text. `nil` unless `proxy.enabled == true` with a valid socks5/http/https
    /// URL. A missing or disabled proxy is silent; a config that can't be parsed, or an enabled
    /// proxy whose URL is rejected, is logged (never the URL itself, which may carry a password).
    static func load(text: String?) -> ProxyConfig? {
        guard let text else { return nil }
        guard let data = text.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            AppLog.warn(.config, "proxy off: \(configPath) is not a JSON object")
            return nil
        }
        guard let proxy = root["proxy"] as? [String: Any], proxy["enabled"] as? Bool == true else { return nil }
        guard let urlString = proxy["url"] as? String,
              let url = URL(string: urlString),
              let schemeRaw = url.scheme?.lowercased(),
              let scheme = Scheme(rawValue: schemeRaw),
              let host = url.host(), !host.isEmpty,
              let port = url.port.map({ UInt16(exactly: $0) }) ?? scheme.defaultPort
        else {
            AppLog.warn(.config, "proxy off: proxy.enabled is true but proxy.url is missing, has a port out of range, or is not a socks5, http or https URL")
            return nil
        }

        return ProxyConfig(
            scheme: scheme,
            host: host,
            port: port,
            username: url.user(percentEncoded: false),
            password: url.password(percentEncoded: false)
        )
    }

    /// The Network-framework proxy this config describes, with loopback always excluded.
    func proxyConfiguration() -> ProxyConfiguration {
        let endpoint = NWEndpoint.hostPort(host: .init(host), port: .init(rawValue: port)!)
        var configuration: ProxyConfiguration
        switch scheme {
        case .socks5:
            configuration = ProxyConfiguration(socksv5Proxy: endpoint)
        case .http:
            configuration = ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: nil)
        case .https:
            configuration = ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: NWProtocolTLS.Options())
        }
        if let username, let password {
            configuration.applyCredential(username: username, password: password)
        }
        configuration.excludedDomains = ["localhost", "127.0.0.1", "::1"]
        return configuration
    }
}
