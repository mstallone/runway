import XCTest
@testable import Runway

/// Resolution checks for the model families added in the October 2026 pricing sync, against the
/// shipped supplement and snapshots.
final class PricingNewModelFamilyTests: XCTestCase {
    private static let pricing = TestPricing.bundled

    /// Grok 4.7 is a Cursor Models row with separate Fast, 500k, and 500k Fast prices.
    func testGrok47PricingAndAliases() throws {
        let pricing = Self.pricing
        let standard = try XCTUnwrap(pricing.resolve(model: "grok-4.7-high"))
        XCTAssertEqual(standard.inputPerMillion, 2.0)
        XCTAssertEqual(standard.cacheWritePerMillion, 2.0)
        XCTAssertEqual(standard.cacheReadPerMillion, 0.5)
        XCTAssertEqual(standard.outputPerMillion, 6.0)
        for slug in ["grok-4.7", "grok-4-7", "cursor-grok-4.7-xhigh", "grok-4.7-build"] {
            XCTAssertEqual(pricing.resolve(model: slug), standard, slug)
        }

        let fast = try XCTUnwrap(pricing.resolve(model: "grok-4.7-fast"))
        XCTAssertEqual(fast.inputPerMillion, 4.0)
        XCTAssertEqual(fast.cacheReadPerMillion, 1.0)
        XCTAssertEqual(fast.outputPerMillion, 12.0)
        for slug in ["grok-4.7-fast-high", "grok-4.7-high-fast", "cursor-grok-4.7-fast"] {
            XCTAssertEqual(pricing.resolve(model: slug), fast, slug)
        }

        let longContext = try XCTUnwrap(pricing.resolve(model: "grok-4.7-500k"))
        XCTAssertEqual(longContext.inputPerMillion, 4.0)
        XCTAssertEqual(longContext.cacheReadPerMillion, 1.0)
        XCTAssertEqual(longContext.outputPerMillion, 12.0)
        XCTAssertEqual(pricing.resolve(model: "grok-4.7[500k]-high"), longContext)

        let longContextFast = try XCTUnwrap(pricing.resolve(model: "grok-4.7-500k-fast"))
        XCTAssertEqual(longContextFast.inputPerMillion, 6.0)
        XCTAssertEqual(longContextFast.cacheReadPerMillion, 1.5)
        XCTAssertEqual(longContextFast.outputPerMillion, 18.0)
        XCTAssertEqual(pricing.resolve(model: "grok-4.7-500k-high-fast"), longContextFast)
        XCTAssertEqual(pricing.resolve(model: "cursor-grok-4.7-500k-fast-high"), longContextFast)
    }

    /// Sonnet 5.5 and Opus 5.5 price from the public catalogs; the supplement only maps Cursor's
    /// thinking, effort, and 1M spellings onto those keys.
    func testClaude55PricingAndAliases() throws {
        let pricing = Self.pricing
        let sonnet = try XCTUnwrap(pricing.resolve(model: "claude-sonnet-5-5"))
        XCTAssertEqual(sonnet.inputPerMillion, 2.0)
        XCTAssertEqual(sonnet.cacheWritePerMillion, 2.5)
        XCTAssertEqual(sonnet.cacheReadPerMillion, 0.2, accuracy: 0.000_001)
        XCTAssertEqual(sonnet.outputPerMillion, 10.0)
        for slug in ["claude-sonnet-5.5", "claude-sonnet-5-5-thinking-high", "claude-sonnet-5-5[1m]"] {
            XCTAssertEqual(pricing.resolve(model: slug), sonnet, slug)
        }

        let opus = try XCTUnwrap(pricing.resolve(model: "claude-opus-5-5"))
        XCTAssertEqual(opus.inputPerMillion, 4.0)
        XCTAssertEqual(opus.cacheWritePerMillion, 5.0)
        XCTAssertEqual(opus.cacheReadPerMillion, 0.2, accuracy: 0.000_001)
        XCTAssertEqual(opus.outputPerMillion, 20.0)
        for slug in ["claude-opus-5.5", "claude-opus-5-5-thinking-xhigh", "claude-5.5-opus-high-thinking"] {
            XCTAssertEqual(pricing.resolve(model: slug), opus, slug)
        }
        let opusFast = try XCTUnwrap(pricing.resolve(model: "claude-opus-5-5-thinking-high-fast"))
        XCTAssertEqual(opusFast.inputPerMillion, 8.0)
        XCTAssertEqual(opusFast.outputPerMillion, 40.0)
        // The Opus 5 rules must not swallow the 5.5 slugs.
        XCTAssertEqual(pricing.resolve(model: "claude-opus-5-thinking-high")?.inputPerMillion, 5.0)
    }

    /// GPT-6 Sol, GPT-6.1 Sol, and GPT-6 Luna price from the public catalogs at OpenAI's rates;
    /// the supplement adds effort aliases and the 2x Fast multiplier.
    func testGPT6SolAndLunaPricingAndAliases() throws {
        let pricing = Self.pricing
        let expected: [(model: String, input: Double, cacheRead: Double, output: Double)] = [
            ("gpt-6.1-sol", 2.0, 0.1, 10.0),
            ("gpt-6-sol", 2.0, 0.2, 10.0),
            ("gpt-6-luna", 0.1, 0.01, 0.5)
        ]
        for entry in expected {
            let rates = try XCTUnwrap(pricing.resolve(model: entry.model), entry.model)
            XCTAssertEqual(rates.inputPerMillion, entry.input, accuracy: 0.000_001, entry.model)
            XCTAssertEqual(rates.cacheReadPerMillion, entry.cacheRead, accuracy: 0.000_001, entry.model)
            XCTAssertEqual(rates.outputPerMillion, entry.output, accuracy: 0.000_001, entry.model)
            XCTAssertEqual(pricing.resolve(model: entry.model + "-xhigh"), rates, entry.model)

            let fast = try XCTUnwrap(pricing.resolve(model: entry.model + "-high-fast"), entry.model)
            XCTAssertEqual(fast.inputPerMillion, entry.input * 2, accuracy: 0.000_001, entry.model)
            XCTAssertEqual(fast.outputPerMillion, entry.output * 2, accuracy: 0.000_001, entry.model)
        }
    }
}
