import XCTest
@testable import ReviewBar

final class MarkdownTests: XCTestCase {
    func testReviewShapedMarkdown() {
        let md = """
        ## Summary
        - Adds a cache
          - nested point
        1. First
        2) Second

        ## Things to check
        **should-fix** `src/a.ts:58`
        still the same paragraph
        ```ts
        await redis.del(key)
          indented()
        ```
        > quoted
        ---
        """
        XCTAssertEqual(MarkdownBlock.parse(md), [
            .heading(level: 2, text: "Summary"),
            .bullet(indent: 0, text: "Adds a cache"),
            .bullet(indent: 1, text: "nested point"),
            .numbered(indent: 0, number: "1", text: "First"),
            .numbered(indent: 0, number: "2", text: "Second"),
            .heading(level: 2, text: "Things to check"),
            .paragraph("**should-fix** `src/a.ts:58`\nstill the same paragraph"),
            .code(language: "ts", text: "await redis.del(key)\n  indented()"),
            .quote("quoted"),
            .rule,
        ])
    }

    func testNotHeadingsOrListsStayText() {
        XCTAssertEqual(MarkdownBlock.parse("#hashtag\n2026 was a year\n-dash"),
                       [.paragraph("#hashtag\n2026 was a year\n-dash")])
    }

    /// Claude sometimes forgets the closing fence; keep the code rather than dropping it.
    func testUnclosedFenceKeepsCode() {
        XCTAssertEqual(MarkdownBlock.parse("```\nlet x = 1"), [.code(language: "", text: "let x = 1")])
    }
}

final class ClaudeErrorsTests: XCTestCase {
    func testUsageLimitWithResetTime() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let m = ClaudeErrors.usageLimitMessage("Claude AI usage limit reached|1790003600", now: now)
        XCTAssertNotNil(m)
        XCTAssertTrue(m!.hasPrefix("Claude usage limit reached. It resets "))
        XCTAssertTrue(m!.hasSuffix("Try again then, or pick a lighter model in Settings."))
    }

    func testUsageLimitWithoutResetTime() {
        XCTAssertEqual(ClaudeErrors.usageLimitMessage("5-hour limit reached ∙ resets 3pm"),
                       "Claude usage limit reached. Try again then, or pick a lighter model in Settings.")
    }

    func testOrdinaryOutputIsNotALimit() {
        XCTAssertNil(ClaudeErrors.usageLimitMessage("## Summary\n- Adds rate limiting to the API"))
    }
}
