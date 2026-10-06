import XCTest
@testable import Runway

final class ProviderParseTests: XCTestCase {
    func testURLFormEncodingPreservesOnlyRFC3986UnreservedASCII() {
        XCTAssertEqual("AZaz09-._~".urlFormEncoded, "AZaz09-._~")
        XCTAssertEqual(
            "space & equals= plus+ slash/ question? percent%".urlFormEncoded,
            "space%20%26%20equals%3D%20plus%2B%20slash%2F%20question%3F%20percent%25"
        )
        XCTAssertEqual("café".urlFormEncoded, "caf%C3%A9")
    }

    func testNumberDistinguishesJSONBooleansFromNumbers() throws {
        let object = try XCTUnwrap(ProviderParse.jsonObject(Data(
            #"{"true":true,"false":false,"one":1,"zero":0,"decimal":1.5,"string":" 2.5 "}"#.utf8
        )))

        XCTAssertNil(ProviderParse.number(object["true"]))
        XCTAssertNil(ProviderParse.number(object["false"]))
        XCTAssertEqual(ProviderParse.number(object["one"]), 1)
        XCTAssertEqual(ProviderParse.number(object["zero"]), 0)
        XCTAssertEqual(ProviderParse.number(object["decimal"]), 1.5)
        XCTAssertEqual(ProviderParse.number(object["string"]), 2.5)
        XCTAssertEqual(ProviderParse.bool(object["true"]), true)
    }

    func testCountHelpersNeverTrapOnOutOfRangeValues() {
        // 2^63 is the first Double that `Int(_:)` cannot hold; `Double(Int.max)` rounds up to it.
        XCTAssertNil(ProviderParse.nonnegativeInt(9_223_372_036_854_775_808.0))
        XCTAssertNil(ProviderParse.nonnegativeInt(1e30))
        XCTAssertNil(ProviderParse.nonnegativeInt(-1))
        XCTAssertNil(ProviderParse.nonnegativeInt(1.5))
        XCTAssertEqual(ProviderParse.nonnegativeInt(42), 42)
        XCTAssertNil(ProviderParse.tokenCount(1e30))
        XCTAssertNil(ProviderParse.tokenCount(-1))
        XCTAssertEqual(ProviderParse.tokenCount(nil), 0)
        XCTAssertEqual(ProviderParse.tokenCount(7), 7)
        XCTAssertEqual(ProviderParse.clampedTokenCount(1e30), 1_000_000_000_000_000)
        XCTAssertEqual(ProviderParse.clampedTokenCount(-5), 0)
        XCTAssertEqual(ProviderParse.clampedTokenCount(nil), 0)
        XCTAssertEqual(ProviderParse.clampedTokenCount("12"), 12)
    }
}
