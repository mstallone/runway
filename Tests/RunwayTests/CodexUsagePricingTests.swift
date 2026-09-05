import XCTest
@testable import Runway

final class CodexUsagePricingTests: XCTestCase {
    func testDatedBaseModelStripsHyphenatedAndCompactSnapshotSuffixes() {
        XCTAssertEqual(CodexUsagePricing.datedBaseModel("gpt-5.5-pro-2026-03-05"), "gpt-5.5-pro")
        XCTAssertEqual(CodexUsagePricing.datedBaseModel("gpt-5.5-pro-20260423"), "gpt-5.5-pro")
        XCTAssertEqual(CodexUsagePricing.datedBaseModel("gpt-5.6-sol"), "gpt-5.6-sol")
    }

    func testAstraLongContextRatesApplyAbove272k() {
        let pricing = ModelPricing(
            supplement: PricingSupplement(pricing: [
                "gpt-6-astra": ModelRates(
                    inputPerMillion: 10,
                    outputPerMillion: 50,
                    cacheWritePerMillion: 12.5,
                    cacheReadPerMillion: 1
                )
            ]),
            primary: PricingCatalog(entries: [:]),
            secondary: PricingCatalog(entries: [:])
        )
        let tokens = TokenBreakdown(input: 200_000, cacheRead: 100_000, output: 10_000)
        // Prompt 300k. Long-context: $20/M input, $2/M cache, $75/M output = $4 + $0.20 + $0.75.
        XCTAssertEqual(
            CodexUsagePricing.estimatedCost(pricing: pricing, model: "gpt-6-astra", tokens: tokens) ?? -1,
            4.95,
            accuracy: 0.000_001
        )
    }
}
