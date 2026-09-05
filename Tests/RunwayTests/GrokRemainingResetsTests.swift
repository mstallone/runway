import XCTest
@testable import Runway

final class GrokRemainingResetsDecoderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_787_000_000)

    func testEmptyDataFrameIsAKnownZero() {
        let decoded = GrokRemainingResetsDecoder.decodeBody(
            GrokRemainingResetsFixtures.emptySuccess(), now: now
        )
        XCTAssertEqual(decoded, GrokRemainingResets(count: 0, expiries: []))
    }

    func testRPCErrorTrailerIsNotAKnownZero() {
        XCTAssertNil(GrokRemainingResetsDecoder.decodeBody(
            GrokRemainingResetsFixtures.grpcTrailer(12), now: now
        ))
        XCTAssertNil(GrokRemainingResetsDecoder.decodeBody(
            GrokRemainingResetsFixtures.grpcTrailer(16), now: now
        ))
        XCTAssertNil(GrokRemainingResetsDecoder.decodeBody(
            GrokRemainingResetsFixtures.grpcFrame(flags: 0x80, payload: Data("grpc-status: nope\r\n".utf8)),
            now: now
        ))
    }

    func testUnframedOrUnmatchedBodiesAreNotZero() {
        XCTAssertNil(GrokRemainingResetsDecoder.decodeBody(Data(), now: now))
        XCTAssertNil(GrokRemainingResetsDecoder.decodeBody(Data(" not grpc ".utf8), now: now))
        // Non-empty proto with no field-10 tokens must not become a trusted 0.
        var unmatched = Data()
        unmatched.append(0x08) // field 1, varint
        unmatched.append(0x01)
        XCTAssertNil(GrokRemainingResetsDecoder.decodeBody(
            GrokRemainingResetsFixtures.grpcFrame(payload: unmatched), now: now
        ))
    }

    func testTruncatedVarintIsNotZero() {
        XCTAssertNil(GrokRemainingResetsDecoder.decodeBody(
            GrokRemainingResetsFixtures.grpcFrame(payload: Data([0x80])), now: now
        ))
        var truncatedHeader = Data([0, 0, 0, 0, 8]) // claims 8-byte payload
        truncatedHeader.append(contentsOf: [1, 2, 3])
        XCTAssertNil(GrokRemainingResetsDecoder.decodeBody(truncatedHeader, now: now))
    }

    func testCountsUnexpiredTokensOnlyAndSortsExpiries() {
        let soon = now.addingTimeInterval(2 * 24 * 3600)
        let later = now.addingTimeInterval(30 * 24 * 3600)
        let past = now.addingTimeInterval(-3600)
        let body = GrokRemainingResetsFixtures.tokens([
            (id: "restok_later", grantedAt: nil, expiresAt: later),
            (id: "restok_expired", grantedAt: nil, expiresAt: past),
            (id: "restok_soon", grantedAt: nil, expiresAt: soon)
        ])
        let decoded = GrokRemainingResetsDecoder.decodeBody(body, now: now)
        XCTAssertEqual(decoded?.count, 2)
        XCTAssertEqual(decoded?.expiries, [soon, later])
    }

    func testLiveShapedTokenWithGrantedAtStillDecodes() {
        // Live tokens carry field 20 (granted_at) plus field 30 (validity_end). Extra fields
        // must not drop a still-valid token.
        let end = now.addingTimeInterval(30 * 24 * 3600)
        let granted = now.addingTimeInterval(-3600)
        let body = GrokRemainingResetsFixtures.tokens([
            (id: "restok_example", grantedAt: granted, expiresAt: end)
        ])
        let decoded = GrokRemainingResetsDecoder.decodeBody(body, now: now)
        XCTAssertEqual(decoded?.count, 1)
        XCTAssertEqual(decoded?.expiries, [end])
    }

    func testIdentifiedTokenMissingValidityEndIsUnknown() {
        var token = Data()
        token.append(0x52) // field 10, wire 2 (token_id)
        let id = Data("restok_example".utf8)
        writeVarint(&token, UInt64(id.count))
        token.append(id)
        var payload = Data()
        payload.append(0x52) // field 10, wire 2 (tokens)
        writeVarint(&payload, UInt64(token.count))
        payload.append(token)
        XCTAssertNil(GrokRemainingResetsDecoder.decodeBody(
            GrokRemainingResetsFixtures.grpcFrame(payload: payload)
                + GrokRemainingResetsFixtures.grpcTrailer(0),
            now: now
        ))
    }

    func testTokenMissingIDIsSkippedNotCounted() {
        let end = now.addingTimeInterval(24 * 3600)
        var token = Data()
        // validity_end only — no token_id.
        var timestamp = Data()
        timestamp.append(0x08) // field 1 varint
        writeVarint(&timestamp, UInt64(end.timeIntervalSince1970))
        token.append(contentsOf: [0xf2, 0x01]) // field 30, wire 2
        writeVarint(&token, UInt64(timestamp.count))
        token.append(timestamp)
        var payload = Data()
        payload.append(0x52) // field 10, wire 2
        writeVarint(&payload, UInt64(token.count))
        payload.append(token)
        let decoded = GrokRemainingResetsDecoder.decodeBody(
            GrokRemainingResetsFixtures.grpcFrame(payload: payload)
                + GrokRemainingResetsFixtures.grpcTrailer(0),
            now: now
        )
        XCTAssertEqual(decoded, GrokRemainingResets(count: 0, expiries: []))
    }

    func testHTTPStatusAndGrpcHeaderRejectUnknownReadings() {
        XCTAssertNil(GrokRemainingResetsDecoder.decode(
            GrokRemainingResetsFixtures.http(GrokRemainingResetsFixtures.emptySuccess(), statusCode: 503),
            now: now
        ))
        XCTAssertNil(GrokRemainingResetsDecoder.decode(
            GrokRemainingResetsFixtures.http(
                GrokRemainingResetsFixtures.emptySuccess(),
                headers: ["grpc-status": "16"]
            ),
            now: now
        ))
        XCTAssertNil(GrokRemainingResetsDecoder.decode(
            GrokRemainingResetsFixtures.http(
                GrokRemainingResetsFixtures.emptySuccess(),
                headers: ["GRPC-Status": "12"]
            ),
            now: now
        ))
        XCTAssertNil(GrokRemainingResetsDecoder.decode(
            GrokRemainingResetsFixtures.http(
                GrokRemainingResetsFixtures.emptySuccess(),
                headers: ["grpc-status": "not-a-number"]
            ),
            now: now
        ))
        XCTAssertEqual(
            GrokRemainingResetsDecoder.decode(
                GrokRemainingResetsFixtures.http(GrokRemainingResetsFixtures.emptySuccess()),
                now: now
            ),
            GrokRemainingResets(count: 0, expiries: [])
        )
    }

    private func writeVarint(_ data: inout Data, _ value: UInt64) {
        var remaining = value
        repeat {
            var byte = UInt8(remaining & 0x7f)
            remaining >>= 7
            if remaining != 0 { byte |= 0x80 }
            data.append(byte)
        } while remaining != 0
    }
}
