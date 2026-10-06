import Foundation
@testable import Runway

extension ClaudeTokenRenewal {
    /// A renewal wired to the test's own token endpoint and credential file, with the kill switch
    /// off and a clock far past any fixture expiry, so a file-sourced credential passes every
    /// guard. "Never renews" assertions then fail if the provider ever asks for a renewal.
    static func observed(tokenEndpoint: any HTTPClient, files: any TextFileAccessing) -> ClaudeTokenRenewal {
        var renewal = ClaudeTokenRenewal()
        renewal.refresher = ClaudeTokenRefresher(httpClient: tokenEndpoint)
        renewal.keychain = FakeKeychain()
        renewal.files = files
        renewal.environment = FakeEnvironment()
        renewal.currentAccount = { "tester" }
        renewal.isDisabled = { false }
        renewal.now = { Date(timeIntervalSince1970: 4_300_000_000) }
        return renewal
    }

    /// A token endpoint that would rotate successfully if a renewal ever reached it.
    static func rotatingTokenEndpoint() -> FakeHTTPClient {
        FakeHTTPClient(response: HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data(#"{"access_token":"new-access","refresh_token":"refresh-2","expires_in":3600}"#.utf8)
        ))
    }
}
