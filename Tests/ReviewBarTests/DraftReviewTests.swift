import Testing
import Foundation
@testable import ReviewBar

struct DraftReviewTests {
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

    @Test func nitsAreLeftOutAndRangesKept() {
        let cs = DraftReview.comments(from: review)
        #expect(cs.map(\.line) == [3, 3, 40])
        #expect(cs[1].startLine == 2)
        #expect(!cs.contains { $0.body.contains("nit:") })
    }

    @Test func multiLineSuggestionWithoutRangeIsDefused() {
        let cs = DraftReview.comments(from: review)
        #expect(!cs[0].body.contains("```suggestion"))
        #expect(cs[1].body.contains("```suggestion"))
    }

    @Test func commentableLines() {
        #expect(DraftReview.commentableLines(diff)["src/a.swift"] == [1, 2, 3, 4])
    }

    @Test func outsideDiffGoesToBody() {
        let body = DraftReview.requestBody(comments: DraftReview.comments(from: review),
                                           commentable: DraftReview.commentableLines(diff), commit: "abc")
        #expect((body["comments"] as? [[String: Any]])?.count == 2)
        #expect((body["body"] as? String)?.contains("src/a.swift:40") == true)
        #expect(body["event"] == nil)   // no event: GitHub keeps it pending
        #expect(body["commit_id"] as? String == "abc")
    }

    @Test func pendingReviewIsFoundFromTheCount() {
        let some = #"{"data":{"repository":{"pullRequest":{"reviews":{"totalCount":1}}}}}"#
        let none = #"{"data":{"repository":{"pullRequest":{"reviews":{"totalCount":0}}}}}"#
        #expect(Backend.parsePendingReview(Data(some.utf8)))
        #expect(!Backend.parsePendingReview(Data(none.utf8)))
    }

    @Test func pendingReviewLookupThatFailsCountsAsNone() {
        #expect(!Backend.parsePendingReview(Data(#"{"data":{"repository":null}}"#.utf8)))
        #expect(!Backend.parsePendingReview(Data("gh: Not Found (HTTP 404)".utf8)))
    }
}
