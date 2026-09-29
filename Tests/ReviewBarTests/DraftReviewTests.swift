import XCTest
@testable import ReviewBar

final class DraftReviewTests: XCTestCase {
    private let review = """
    ### [blocker] `src/a.swift:3` Crash
    > Guests crash here; moving the check up fixes it.
    ```suggestion
    guard let org = user?.org else { return }
    let name = org.name
    ```

    ### [should-fix] `src/a.swift:2-3` Two lines
    > Swap these.
    ```suggestion
    let b = 3
    let a = 2
    ```

    ### [question] `src/a.swift:40` Archived?
    > question: Is this meant to include archived projects?

    ### [nit] `src/a.swift:4` Naming
    > nit: rename.
    """

    private let diff = """
    diff --git a/src/a.swift b/src/a.swift
    --- a/src/a.swift
    +++ b/src/a.swift
    @@ -1,3 +1,4 @@
     import Foundation
    -let a = 1
    +let a = 2
    +let b = 3
     print(a)
    """

    func testNitsAreLeftOutAndRangesKept() {
        let cs = DraftReview.comments(from: review)
        XCTAssertEqual(cs.map(\.line), [3, 3, 40])
        XCTAssertEqual(cs[1].startLine, 2)
        XCTAssertFalse(cs.contains { $0.body.contains("nit:") })
    }

    func testMultiLineSuggestionWithoutRangeIsDefused() {
        let cs = DraftReview.comments(from: review)
        XCTAssertFalse(cs[0].body.contains("```suggestion"))
        XCTAssertTrue(cs[1].body.contains("```suggestion"))
    }

    func testCommentableLines() {
        XCTAssertEqual(DraftReview.commentableLines(diff)["src/a.swift"], [1, 2, 3, 4])
    }

    func testOutsideDiffGoesToBody() {
        let body = DraftReview.requestBody(comments: DraftReview.comments(from: review),
                                           commentable: DraftReview.commentableLines(diff), commit: "abc")
        XCTAssertEqual((body["comments"] as? [[String: Any]])?.count, 2)
        XCTAssertTrue((body["body"] as? String)?.contains("src/a.swift:40") == true)
        XCTAssertNil(body["event"])   // no event: GitHub keeps it pending
        XCTAssertEqual(body["commit_id"] as? String, "abc")
    }
}
