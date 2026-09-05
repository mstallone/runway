import Foundation
@testable import Runway

/// Builders for Grok's `GetRemainingResets` gRPC-web payloads. Synthetic only — never a live
/// account's token id.
enum GrokRemainingResetsFixtures {
    static func http(_ body: Data, statusCode: Int = 200, headers: [String: String] = [:]) -> HTTPResponse {
        HTTPResponse(statusCode: statusCode, headers: headers, body: body)
    }

    static func emptySuccess() -> Data {
        grpcFrame(payload: Data()) + grpcTrailer(0)
    }

    static func grpcTrailer(_ status: Int) -> Data {
        grpcFrame(flags: 0x80, payload: Data("grpc-status: \(status)\r\n".utf8))
    }

    static func tokens(
        _ items: [(id: String, grantedAt: Date?, expiresAt: Date)]
    ) -> Data {
        var payload = Data()
        for item in items {
            var token = Data()
            writeString(&token, field: GrokRemainingResetsDecoder.tokenIDField, item.id)
            if let grantedAt = item.grantedAt {
                writeTimestamp(&token, field: 20, grantedAt)
            }
            writeTimestamp(&token, field: GrokRemainingResetsDecoder.tokenEndField, item.expiresAt)
            writeBytes(&payload, field: GrokRemainingResetsDecoder.tokenField, token)
        }
        return grpcFrame(payload: payload) + grpcTrailer(0)
    }

    static func grpcFrame(flags: UInt8 = 0, payload: Data) -> Data {
        var frame = Data([flags])
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }

    private static func writeTimestamp(_ data: inout Data, field: UInt64, _ date: Date) {
        var timestamp = Data()
        writeKey(&timestamp, field: 1, wire: 0)
        writeVarint(&timestamp, UInt64(date.timeIntervalSince1970.rounded(.towardZero)))
        writeBytes(&data, field: field, timestamp)
    }

    private static func writeString(_ data: inout Data, field: UInt64, _ value: String) {
        writeBytes(&data, field: field, Data(value.utf8))
    }

    private static func writeBytes(_ data: inout Data, field: UInt64, _ bytes: Data) {
        writeKey(&data, field: field, wire: 2)
        writeVarint(&data, UInt64(bytes.count))
        data.append(bytes)
    }

    private static func writeKey(_ data: inout Data, field: UInt64, wire: UInt64) {
        writeVarint(&data, (field << 3) | wire)
    }

    private static func writeVarint(_ data: inout Data, _ value: UInt64) {
        var remaining = value
        repeat {
            var byte = UInt8(remaining & 0x7f)
            remaining >>= 7
            if remaining != 0 { byte |= 0x80 }
            data.append(byte)
        } while remaining != 0
    }
}
