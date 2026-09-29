import XCTest
@testable import ReviewBar

final class ReviewDocTests: XCTestCase {
    func testVerdictAndFindingBoxes() {
        let doc = ReviewDoc.parse("""
        VERDICT: Request changes — refresh can race.

        ## Findings
        ### [blocker] `a.swift:4` Race
        Why: two refreshes.
        > Could two requests hit this at once?

        ### [nit] `a.swift:9` Stray print

        ## Good
        - Tests.
        """)
        XCTAssertEqual(doc.first, .verdict(.requestChanges, reason: "refresh can race."))
        let findings = doc.compactMap { s -> ReviewDoc.Severity?? in
            if case .finding(let sev, _, _) = s { return sev } else { return nil }
        }
        XCTAssertEqual(findings, [.blocker, .nit])
        XCTAssertTrue(doc.contains(.block(.heading(level: 2, text: "Good"))))
    }

    func testLegacyLeanBecomesVerdict() {
        XCTAssertEqual(ReviewDoc.parse("## Lean\nApprove, small and safe.").first,
                       .verdict(.approve, reason: "small and safe."))
    }

    func testNoVerdictIsFine() {
        XCTAssertEqual(ReviewDoc.parse("Just notes."), [.block(.paragraph("Just notes."))])
    }
}
