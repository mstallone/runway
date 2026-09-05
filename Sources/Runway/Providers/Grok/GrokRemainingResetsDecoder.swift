import Foundation

/// Banked Grok usage-limit resets from `GetRemainingResets`: the still-valid count plus each
/// token's expiry, soonest-first. A decoded value (including count 0) is a known reading; `nil`
/// from the decoder means the payload was unusable and the row should be omitted.
struct GrokRemainingResets: Equatable, Sendable {
    var count: Int
    var expiries: [Date]
}

/// Decode grok.com's `prod_mc_billing.ConsumerUiSvc/GetRemainingResets` gRPC-web response.
///
/// Field numbers match `consumer_ui.proto` as shipped by grok.com (verified live 2026-08-23):
/// `ConsumerGetRemainingResetsResp.tokens` is field 10, each `ConsumerResetToken` carries
/// `token_id` (field 10, string) and `validity_end` (field 30, `google.protobuf.Timestamp`).
/// Tokens missing an id or whose end is in the past are ignored, matching grok.com's own filter.
///
/// A known zero is an empty gRPC-web data frame (optionally with `grpc-status: 0`). Trailer
/// errors, unframed bodies, truncated proto, and messages with no `tokens` field stay unknown
/// rather than 0 — a failed fetch must not render as "0 available".
enum GrokRemainingResetsDecoder {
    static let tokenField: UInt64 = 10
    static let tokenIDField: UInt64 = 10
    static let tokenEndField: UInt64 = 30

    /// Empty uncompressed gRPC-web data frame — the request body `GetRemainingResets` expects.
    static let emptyRequest = Data([0, 0, 0, 0, 0])

    static func decode(_ response: HTTPResponse, now: Date = Date()) -> GrokRemainingResets? {
        guard (200..<300).contains(response.statusCode) else { return nil }
        if let headerStatus = grpcStatus(inHTTPHeaders: response.headers), headerStatus != 0 {
            return nil
        }
        return decodeBody(response.body, now: now)
    }

    static func decodeBody(_ data: Data, now: Date) -> GrokRemainingResets? {
        guard let split = grpcWebSplit(data) else { return nil }
        if let trailerStatus = grpcStatus(inTrailers: split.trailers), trailerStatus != 0 {
            return nil
        }
        guard !split.frames.isEmpty else { return nil }

        var expiries: [Date] = []
        for frame in split.frames {
            if frame.isEmpty { continue }
            guard let (frameExpiries, sawTokens) = availableExpiries(in: frame, now: now) else {
                return nil
            }
            guard sawTokens else { return nil }
            expiries.append(contentsOf: frameExpiries)
        }
        expiries.sort()
        return GrokRemainingResets(count: expiries.count, expiries: expiries)
    }

    private static func availableExpiries(in data: Data, now: Date) -> (expiries: [Date], sawTokens: Bool)? {
        guard let fields = protoFields(data) else { return nil }
        var expiries: [Date] = []
        var sawTokens = false
        for field in fields {
            guard field.number == tokenField, field.wire == 2 else { continue }
            sawTokens = true
            guard let expiry = availableExpiry(in: field.bytes, now: now) else { return nil }
            if let expiry { expiries.append(expiry) }
        }
        return (expiries, sawTokens)
    }

    /// `nil` = truncated/malformed token; `.some(nil)` = well-formed but not currently available.
    private static func availableExpiry(in data: Data, now: Date) -> Date?? {
        guard let fields = protoFields(data) else { return nil }
        var tokenID: String?
        var validityEnd: Date?
        for field in fields {
            switch (field.number, field.wire) {
            case (tokenIDField, 2):
                let text = String(data: field.bytes, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !text.isEmpty { tokenID = text }
            case (tokenEndField, 2):
                guard let parsed = protoTimestamp(field.bytes) else { return nil }
                validityEnd = parsed
            default:
                continue
            }
        }
        guard let tokenID, !tokenID.isEmpty, let validityEnd, validityEnd > now else {
            return .some(nil)
        }
        return validityEnd
    }

    private static func protoTimestamp(_ data: Data) -> Date? {
        guard let fields = protoFields(data) else { return nil }
        for field in fields where field.number == 1 && field.wire == 0 {
            let seconds = Int64(bitPattern: field.varint)
            return Date(timeIntervalSince1970: TimeInterval(seconds))
        }
        return nil
    }

    private static func grpcStatus(inHTTPHeaders headers: [String: String]) -> Int? {
        if let raw = headers["grpc-status"] ?? headers["Grpc-Status"] {
            return Int(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func grpcStatus(inTrailers trailers: [Data]) -> Int? {
        for trailer in trailers {
            guard let text = String(data: trailer, encoding: .utf8) else { continue }
            for line in text.split(whereSeparator: { $0 == "\r" || $0 == "\n" }) {
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "grpc-status" else {
                    continue
                }
                return Int(parts[1].trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    private struct GrpcWebSplit {
        var frames: [Data]
        var trailers: [Data]
    }

    /// Walk consecutive gRPC-web frames. Flag high bit set (0x80) is a trailer; otherwise data.
    /// Returns `nil` on a truncated frame header or incomplete payload.
    private static func grpcWebSplit(_ data: Data) -> GrpcWebSplit? {
        var frames: [Data] = []
        var trailers: [Data] = []
        var offset = 0
        while offset < data.count {
            guard offset + 5 <= data.count else { return nil }
            let flags = data[offset]
            let length = data.subdata(in: (offset + 1)..<(offset + 5)).reduce(0) { ($0 << 8) | UInt32($1) }
            offset += 5
            let end = offset + Int(length)
            guard end <= data.count else { return nil }
            let payload = data.subdata(in: offset..<end)
            offset = end
            if flags & 0x80 != 0 {
                trailers.append(payload)
            } else {
                frames.append(payload)
            }
        }
        return GrpcWebSplit(frames: frames, trailers: trailers)
    }

    private struct ProtoField {
        var number: UInt64
        var wire: UInt64
        var varint: UInt64
        var bytes: Data
    }

    private static func protoFields(_ data: Data) -> [ProtoField]? {
        var fields: [ProtoField] = []
        var offset = 0
        while offset < data.count {
            guard let (key, afterKey) = readVarint(data, at: offset) else { return nil }
            offset = afterKey
            let number = key >> 3
            let wire = key & 0x07
            switch wire {
            case 0:
                guard let (value, afterValue) = readVarint(data, at: offset) else { return nil }
                offset = afterValue
                fields.append(ProtoField(number: number, wire: wire, varint: value, bytes: Data()))
            case 1:
                guard offset + 8 <= data.count else { return nil }
                offset += 8
                fields.append(ProtoField(number: number, wire: wire, varint: 0, bytes: Data()))
            case 2:
                guard let (length, afterLength) = readVarint(data, at: offset) else { return nil }
                offset = afterLength
                let end = offset + Int(length)
                guard end <= data.count else { return nil }
                fields.append(ProtoField(
                    number: number, wire: wire, varint: 0,
                    bytes: data.subdata(in: offset..<end)
                ))
                offset = end
            case 5:
                guard offset + 4 <= data.count else { return nil }
                offset += 4
                fields.append(ProtoField(number: number, wire: wire, varint: 0, bytes: Data()))
            default:
                return nil
            }
        }
        return fields
    }

    private static func readVarint(_ data: Data, at start: Int) -> (UInt64, Int)? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        var offset = start
        while offset < data.count {
            let byte = data[offset]
            offset += 1
            value |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return (value, offset) }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }
}
