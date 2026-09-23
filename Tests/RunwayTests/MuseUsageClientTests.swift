import XCTest
@testable import Runway

@MainActor
final class MuseUsageClientTests: XCTestCase {
    func testReadsTeamsThenJSONQuotaUsingOnlyTheCurrentBrowserCookie() async throws {
        let http = museHTTP { _ in museResponse() }
        let response = try await MuseUsageClient(http: http).fetchUsage(sessionToken: museToken)
        XCTAssertEqual(try MuseUsageMapper.map(response.body).plan, "Power Usage")
        XCTAssertEqual(http.requests.map(\.url), [MuseUsageClient.teamsURL, museQuotaURL])
        for request in http.requests {
            XCTAssertEqual(request.method, "GET")
            XCTAssertEqual(request.headers["Cookie"], "llama_dev_sess=\(museToken)")
            XCTAssertEqual(request.headers["Accept"], "application/json")
            XCTAssertNil(request.headers["Authorization"])
            XCTAssertNil(request.body)
        }
    }

    func testTriesNextTeamOnlyWhenQuotaIsExplicitlyNull() async throws {
        let http = RoutingHTTPClient { request in
            if request.url == MuseUsageClient.teamsURL {
                return museResponse(#"{"teams":[{"team_id":"no-subscription"},{"team_id":"personal"}]}"#)
            }
            if request.url.path.contains("no-subscription") {
                return museResponse(#"{"subscription_quota":null}"#)
            }
            return museResponse()
        }
        let response = try await MuseUsageClient(http: http).fetchUsage(sessionToken: museToken)
        XCTAssertEqual(try MuseUsageMapper.map(response.body).lines.count, 2)
        XCTAssertEqual(http.requests.count, 3)
    }

    func testTeamRateLimitStopsBeforeAnyQuotaRequestAndPreservesRetryAfter() async throws {
        let http = RoutingHTTPClient { _ in museResponse("", status: 429, headers: ["retry-after": "3600"]) }
        let response = try await MuseUsageClient(http: http).fetchUsage(sessionToken: museToken)
        XCTAssertEqual(response.statusCode, 429)
        XCTAssertEqual(response.header("retry-after"), "3600")
        XCTAssertEqual(http.requests.count, 1)
    }

    func testQuotaRateLimitDoesNotTryOtherTeams() async throws {
        let http = RoutingHTTPClient { request in
            if request.url == MuseUsageClient.teamsURL {
                return museResponse(#"{"teams":[{"team_id":"one"},{"team_id":"two"}]}"#)
            }
            return museResponse("", status: 429)
        }
        let response = try await MuseUsageClient(http: http).fetchUsage(sessionToken: museToken)
        XCTAssertEqual(response.statusCode, 429)
        XCTAssertEqual(http.requests.count, 2)
    }

    func testUnusableTeamListNeverCreatesAQuotaRequest() async {
        for body in ["{}", #"{"teams":[{}]}"#, #"{"teams":[{"team_id":"../logout"}]}"#] {
            let http = RoutingHTTPClient { _ in museResponse(body) }
            do {
                _ = try await MuseUsageClient(http: http).fetchUsage(sessionToken: museToken)
                XCTFail("Expected invalid response")
            } catch {
                XCTAssertEqual(error as? MuseUsageError, .invalidResponse)
            }
            XCTAssertEqual(http.requests.count, 1)
        }
    }

    func testPortalClientRejectsEveryRedirectIncludingSameHostLogin() async {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: MuseUsageClient.teamsURL)
        for address in ["https://dev.meta.ai/", "https://auth.meta.com/login", "https://dev.meta.ai/api/portal/teams/"] {
            let redirected: URLRequest? = await withCheckedContinuation { continuation in
                MusePortalRedirects().urlSession(
                    session, task: task,
                    willPerformHTTPRedirection: HTTPURLResponse(url: MuseUsageClient.teamsURL, statusCode: 302, httpVersion: nil, headerFields: nil)!,
                    newRequest: URLRequest(url: URL(string: address)!),
                    completionHandler: { continuation.resume(returning: $0) }
                )
            }
            XCTAssertNil(redirected)
        }
    }
}
