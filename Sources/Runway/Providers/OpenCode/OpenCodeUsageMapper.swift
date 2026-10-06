import Foundation

/// Turns `GET /zen/go/v1/usage` into the three Go plan meters. The endpoint reports percent used
/// (same numbers as the OpenCode dashboard) plus an ISO reset time — not dollar spend — so each row
/// is a `.percent` progress meter.
enum OpenCodeUsageMapper {
    /// Maximum distance from exactly one full period for a zero-usage rolling reset to count as the
    /// untouched-window placeholder. OpenCode rounds the reset up to whole seconds and HTTP `Date`
    /// headers carry whole-second precision, so two seconds covers both rounding steps. A session that
    /// starts inside that narrow interval is indistinguishable in one response and can read "Not
    /// started" until the next refresh; widening the tolerance would lengthen that stale state.
    static let placeholderResetTolerance: TimeInterval = 2

    /// `requestedAt` and `receivedAt` are the local times just before the request was sent and just
    /// after its response arrived.
    static func meterLines(_ response: HTTPResponse, requestedAt: Date, receivedAt: Date) throws -> [MetricLine] {
        guard let body = ProviderParse.jsonObject(response.body) else {
            throw OpenCodeUsageError.invalidResponse
        }
        // Compare two server-authored instants when possible, which removes Mac clock skew from the
        // placeholder test. HTTP allows a response without a usable `Date` header. Then the server
        // computed the reset at some unknown instant while the request was in flight, so the whole
        // request interval stands in for it. A slow response would otherwise put the placeholder
        // outside the tolerance and show a five-hour countdown on an untouched session. The cost is
        // that a session started during that request reads "Not started" until the next refresh.
        let serverDate = response.header("date")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap(HTTPDateFormatter.date(from:))
        let serverTime = serverDate.map { $0...$0 } ?? min(requestedAt, receivedAt)...max(requestedAt, receivedAt)
        return try meterLines(body: body, serverTime: serverTime)
    }

    /// `serverTime` bounds the instant the server answered: a single instant when it is known.
    static func meterLines(body: [String: Any], serverTime: ClosedRange<Date>) throws -> [MetricLine] {
        guard let usage = body["usage"] as? [String: Any] else {
            throw OpenCodeUsageError.invalidResponse
        }
        return [
            try window(usage["rolling"], label: "Session", periodMs: MetricPeriod.sessionMs,
                       serverTime: serverTime, isRollingSession: true),
            try window(usage["weekly"], label: "Weekly", periodMs: MetricPeriod.weekMs, serverTime: serverTime),
            try window(usage["monthly"], label: "Monthly", periodMs: MetricPeriod.monthMs, serverTime: serverTime)
        ]
    }

    /// The upstream error discriminator (`AuthError`, `EntitlementError`, …), when the body is the
    /// documented `{ type, error: { type, message } }` shape. `nil` for HTML/Cloudflare/empty bodies.
    static func errorType(in response: HTTPResponse) -> String? {
        guard let body = ProviderParse.jsonObject(response.body),
              let error = body["error"] as? [String: Any],
              let type = (error["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !type.isEmpty
        else { return nil }
        return type
    }

    /// One window. `isRollingSession` turns on the placeholder handling: with no calls inside the
    /// window there is nothing to roll off, so the API answers `resetsAt = now + 5h` and re-derives it
    /// on every request. That placeholder means "if you started now", so it is dropped to `nil` here
    /// and the Session row reads "Not started" off the missing reset (`SessionStartSignal`). This runs
    /// at capture time because the full-period comparison is exact only at the instant the snapshot is
    /// taken and drifts every second afterwards.
    ///
    /// A window with real usage anchors its reset to the oldest call, so the reset sits inside the
    /// period and keeps its countdown. That includes a session under 1% used, where the whole-percent
    /// `percent` field reads 0. Weekly and monthly opt out: their resets are calendar and billing
    /// instants that exist regardless of usage, and early in a cycle one sits nearly a full period out.
    ///
    /// The rolling session without a parseable `resetsAt` is an invalid response: accepting it would
    /// make a malformed reset look like an untouched window. Weekly and monthly have no such state, so
    /// they keep their meter without a countdown and log a warning.
    private static func window(
        _ raw: Any?,
        label: String,
        periodMs: Int,
        serverTime: ClosedRange<Date>,
        isRollingSession: Bool = false
    ) throws -> MetricLine {
        guard let object = raw as? [String: Any],
              let percent = ProviderParse.number(object["percent"])
        else {
            throw OpenCodeUsageError.invalidResponse
        }
        let used = ProviderParse.clampPercent(percent)
        var resetsAt = (object["resetsAt"] as? String).flatMap(RunwayISO8601.date(from:))
        if isRollingSession {
            guard let reportedReset = resetsAt else { throw OpenCodeUsageError.invalidResponse }
            // The placeholder is the server's clock plus one period, so it implies when the server
            // answered. It is the placeholder when that instant fits `serverTime`.
            let impliedServerTime = reportedReset.addingTimeInterval(-TimeInterval(periodMs) / 1000)
            let earliest = serverTime.lowerBound.addingTimeInterval(-placeholderResetTolerance)
            let latest = serverTime.upperBound.addingTimeInterval(placeholderResetTolerance)
            if used == 0, impliedServerTime >= earliest, impliedServerTime <= latest {
                resetsAt = nil
            }
        } else if resetsAt == nil {
            AppLog.warn(
                LogTag.plugin("opencode"),
                "Go usage: \(label) window has no usable resetsAt; showing the meter without a countdown"
            )
        }
        return .progress(
            label: label,
            used: used,
            limit: 100,
            format: .percent,
            resetsAt: resetsAt,
            periodDurationMs: periodMs
        )
    }
}
