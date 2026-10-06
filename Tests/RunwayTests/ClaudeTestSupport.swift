import Foundation
@testable import Runway

extension ClaudeTokenRenewal {
    /// A renewal wired to the test's own token endpoint and credential stores, with every guard
    /// open: the kill switch off, a clock far past any fixture expiry, and a keychain write path
    /// that reports itself authorized. A file- or keychain-sourced credential therefore reaches
    /// the token endpoint, so "never renews" assertions fail if the provider ever asks.
    static func observed(
        tokenEndpoint: any HTTPClient,
        files: any TextFileAccessing,
        keychain: any KeychainReading = FakeKeychain()
    ) -> ClaudeTokenRenewal {
        var writeBack = ClaudeCredentialWriteBack()
        writeBack.helperIsSilentlyAuthorized = { _, _ in true }
        writeBack.stdinRunner = AcceptingStdinRunner()
        var renewal = ClaudeTokenRenewal()
        renewal.refresher = ClaudeTokenRefresher(httpClient: tokenEndpoint)
        renewal.writeBack = writeBack
        renewal.keychain = keychain
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

private struct AcceptingStdinRunner: StdinProcessRunning {
    func run(executable: String, arguments: [String], stdin: String, timeout: TimeInterval) throws -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: "", stderr: "")
    }
}
