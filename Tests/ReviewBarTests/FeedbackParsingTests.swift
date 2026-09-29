import XCTest
@testable import ReviewBar

/// Feeds sample GraphQL responses (shaped like `repliesQuery` / `myPRsQuery`) to the parsers.
final class FeedbackParsingTests: XCTestCase {

    // MARK: Replies on threads I took part in

    private func replyNode(_ number: Int, threads: String) -> String {
        """
        {"number": \(number), "title": "PR \(number)", "url": "https://github.com/o/r/pull/\(number)",
         "isDraft": false, "updatedAt": "2026-09-01T00:00:00Z", "headRefOid": "abc1234def",
         "repository": {"nameWithOwner": "o/r"}, "author": {"login": "alice"},
         "reviewThreads": {"nodes": [\(threads)]}}
        """
    }

    private func thread(resolved: Bool = false, opener: String, recent: [(String, String)]) -> String {
        let r = recent.map { #"{"author": {"login": "\#($0.0)"}, "createdAt": "\#($0.1)"}"# }
        return """
        {"isResolved": \(resolved),
         "opener": {"nodes": [{"author": {"login": "\(opener)"}}]},
         "recent": {"nodes": [\(r.joined(separator: ","))]}}
        """
    }

    private func repliesJSON(_ nodes: [String]) -> Data {
        Data(#"{"data": {"viewer": {"login": "me"}, "search": {"nodes": [\#(nodes.joined(separator: ","))]}}}"#.utf8)
    }

    func testReplyAfterMyCommentIsWaiting() throws {
        let t = thread(opener: "me", recent: [("me", "2026-09-01T10:00:00Z"), ("alice", "2026-09-02T10:00:00Z")])
        let replies = try Backend.parseReplies(repliesJSON([replyNode(1, threads: t)]))
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(replies[0].waiting, 1)
        XCTAssertEqual(replies[0].latestBy, "alice")
        XCTAssertEqual(replies[0].latestAt, "2026-09-02T10:00:00Z")
        XCTAssertEqual(replies[0].pr.headRefOid, "abc1234def")
    }

    func testNotWaitingWhenIAnsweredLastResolvedOrNotMine() throws {
        let iAnswered = thread(opener: "me", recent: [("alice", "2026-09-02T10:00:00Z"), ("me", "2026-09-03T10:00:00Z")])
        let resolved = thread(resolved: true, opener: "me", recent: [("alice", "2026-09-02T10:00:00Z")])
        let notMine = thread(opener: "bob", recent: [("bob", "2026-09-01T10:00:00Z"), ("alice", "2026-09-02T10:00:00Z")])
        let replies = try Backend.parseReplies(repliesJSON([replyNode(2, threads: [iAnswered, resolved, notMine].joined(separator: ","))]))
        XCTAssertTrue(replies.isEmpty)
    }

    func testRepliesSortedNewestFirstAndCounted() throws {
        let older = thread(opener: "me", recent: [("alice", "2026-09-02T10:00:00Z")])
        let newer = thread(opener: "me", recent: [("bob", "2026-09-05T10:00:00Z")])
        let replies = try Backend.parseReplies(repliesJSON([
            replyNode(3, threads: older),
            replyNode(4, threads: [older, newer].joined(separator: ",")),
        ]))
        XCTAssertEqual(replies.map(\.pr.number), [4, 3])
        XCTAssertEqual(replies[0].waiting, 2)
        XCTAssertEqual(replies[0].latestBy, "bob")
    }

    func testNullNodesAreSkipped() throws {
        let replies = try Backend.parseReplies(repliesJSON(["null", "{}"]))
        XCTAssertTrue(replies.isEmpty)
    }

    // MARK: Feedback on my own PRs

    private func user(_ login: String, bot: Bool = false) -> String {
        #"{"login": "\#(login)", "__typename": "\#(bot ? "Bot" : "User")"}"#
    }

    private func myPRsJSON(lastCommit: String = "2026-09-10T00:00:00Z", decision: String = "REVIEW_REQUIRED",
                           reviews: [String] = [], comments: [String] = [], threads: [String] = [],
                           checks: String? = nil, mergeable: String? = nil) -> Data {
        let rollup = checks.map { #"{"state": "\#($0)"}"# } ?? "null"
        let merge = mergeable.map { "\"\($0)\"" } ?? "null"
        return Data("""
        {"data": {"viewer": {"login": "me"}, "search": {"nodes": [
          {"number": 7, "title": "Mine", "url": "https://github.com/o/r/pull/7", "isDraft": false,
           "updatedAt": "2026-09-11T00:00:00Z", "headRefOid": "fff0000", "reviewDecision": "\(decision)",
           "mergeable": \(merge),
           "repository": {"nameWithOwner": "o/r"}, "author": {"login": "me"},
           "commits": {"nodes": [{"commit": {"committedDate": "\(lastCommit)", "statusCheckRollup": \(rollup)}}]},
           "reviews": {"nodes": [\(reviews.joined(separator: ","))]},
           "comments": {"nodes": [\(comments.joined(separator: ","))]},
           "reviewThreads": {"nodes": [\(threads.joined(separator: ","))]}}
        ]}}}
        """.utf8)
    }

    private func review(_ who: String, _ state: String, _ at: String, body: String = "", bot: Bool = false) -> String {
        #"{"author": \#(user(who, bot: bot)), "state": "\#(state)", "body": "\#(body)", "submittedAt": "\#(at)"}"#
    }

    private func comment(_ who: String, _ at: String, bot: Bool = false) -> String {
        #"{"author": \#(user(who, bot: bot)), "createdAt": "\#(at)"}"#
    }

    private func myThread(resolved: Bool = false, last: String) -> String {
        #"{"isResolved": \#(resolved), "comments": {"nodes": [\#(last)]}}"#
    }

    func testChangeRequestAfterLastCommitCounts() throws {
        let prs = try Backend.parseMyPRs(myPRsJSON(
            decision: "CHANGES_REQUESTED",
            reviews: [review("alice", "CHANGES_REQUESTED", "2026-09-11T09:00:00Z")]))
        XCTAssertEqual(prs.count, 1)
        XCTAssertEqual(prs[0].reviews, 1)
        XCTAssertEqual(prs[0].decision, "CHANGES_REQUESTED")
        XCTAssertEqual(prs[0].latestBy, "alice")
        XCTAssertEqual(prs[0].summary, "1 review")
    }

    func testFeedbackOlderThanMyLastCommitIsAnswered() throws {
        let prs = try Backend.parseMyPRs(myPRsJSON(
            reviews: [review("alice", "CHANGES_REQUESTED", "2026-09-09T09:00:00Z")],
            comments: [comment("bob", "2026-09-08T09:00:00Z")]))
        XCTAssertTrue(prs.isEmpty)
    }

    func testMyLaterCommentCountsAsAnswer() throws {
        let prs = try Backend.parseMyPRs(myPRsJSON(
            comments: [comment("bob", "2026-09-11T09:00:00Z"), comment("me", "2026-09-11T10:00:00Z")]))
        XCTAssertTrue(prs.isEmpty)
    }

    func testBotsAreIgnored() throws {
        let prs = try Backend.parseMyPRs(myPRsJSON(
            reviews: [review("coverage", "COMMENTED", "2026-09-11T09:00:00Z", body: "Coverage 91%", bot: true)],
            comments: [comment("ci", "2026-09-11T09:00:00Z", bot: true)],
            threads: [myThread(last: comment("lint", "2026-09-11T09:00:00Z", bot: true))]))
        XCTAssertTrue(prs.isEmpty)
    }

    /// A COMMENTED review with no summary only wraps thread comments, which are counted as threads.
    func testEmptyCommentedReviewIsNotCountedTwice() throws {
        let prs = try Backend.parseMyPRs(myPRsJSON(
            reviews: [review("alice", "COMMENTED", "2026-09-11T09:00:00Z")],
            threads: [myThread(last: comment("alice", "2026-09-11T09:00:00Z"))]))
        XCTAssertEqual(prs.count, 1)
        XCTAssertEqual(prs[0].threads, 1)
        XCTAssertEqual(prs[0].reviews, 0)
        XCTAssertEqual(prs[0].summary, "1 thread")
    }

    func testUnresolvedThreadWaitsEvenIfOlderThanLastCommit() throws {
        let prs = try Backend.parseMyPRs(myPRsJSON(
            threads: [myThread(last: comment("alice", "2026-09-01T09:00:00Z")),
                      myThread(resolved: true, last: comment("bob", "2026-09-01T09:00:00Z")),
                      myThread(last: comment("me", "2026-09-02T09:00:00Z"))]))
        XCTAssertEqual(prs.count, 1)
        XCTAssertEqual(prs[0].threads, 1)
    }

    func testSummaryPluralsAndOrder() throws {
        let prs = try Backend.parseMyPRs(myPRsJSON(
            reviews: [review("alice", "APPROVED", "2026-09-11T09:00:00Z")],
            comments: [comment("bob", "2026-09-11T08:00:00Z"), comment("carol", "2026-09-11T12:00:00Z")],
            threads: [myThread(last: comment("alice", "2026-09-11T07:00:00Z")),
                      myThread(last: comment("bob", "2026-09-11T06:00:00Z"))]))
        XCTAssertEqual(prs[0].summary, "2 threads · 1 review · 2 comments")
        XCTAssertEqual(prs[0].latestBy, "carol")
    }

    // MARK: CI and merge state

    func testApprovedGreenMergeableIsListedAsReady() throws {
        let prs = try Backend.parseMyPRs(myPRsJSON(
            decision: "APPROVED",
            reviews: [review("alice", "APPROVED", "2026-09-09T09:00:00Z")],   // before last commit: no feedback
            checks: "SUCCESS", mergeable: "MERGEABLE"))
        XCTAssertEqual(prs.count, 1)
        XCTAssertTrue(prs[0].readyToMerge)
        XCTAssertEqual(prs[0].summary, "Ready to merge")
        XCTAssertEqual(prs[0].latestAt, "2026-09-09T09:00:00Z")   // the approval: stable for dismissing
        XCTAssertEqual(prs[0].latestBy, "alice")
    }

    func testFailingChecksAndConflictsAreListed() throws {
        let failing = try Backend.parseMyPRs(myPRsJSON(checks: "FAILURE", mergeable: "MERGEABLE"))
        XCTAssertEqual(failing.first?.status, "Checks failing")
        XCTAssertEqual(failing.first?.latestAt, "2026-09-10T00:00:00Z")   // the head commit
        let conflict = try Backend.parseMyPRs(myPRsJSON(checks: "SUCCESS", mergeable: "CONFLICTING"))
        XCTAssertEqual(conflict.first?.status, "Merge conflict")
    }

    func testQuietPRsStayHidden() throws {
        XCTAssertTrue(try Backend.parseMyPRs(myPRsJSON(checks: "SUCCESS", mergeable: "MERGEABLE")).isEmpty)
        XCTAssertTrue(try Backend.parseMyPRs(myPRsJSON(checks: "PENDING", mergeable: "UNKNOWN")).isEmpty)
    }

    func testFeedbackRowsStillShowCountsWithStatus() throws {
        let prs = try Backend.parseMyPRs(myPRsJSON(
            comments: [comment("bob", "2026-09-11T09:00:00Z")], checks: "FAILURE", mergeable: "MERGEABLE"))
        XCTAssertEqual(prs[0].summary, "1 comment")
        XCTAssertEqual(prs[0].status, "Checks failing")
    }

    // MARK: Review keys

    func testReviewKeyUsesHeadCommitWhenKnown() {
        var pr = PR(number: 1, title: "t", url: "u", isDraft: false, updatedAt: "2026-09-01T00:00:00Z",
                    repository: .init(nameWithOwner: "o/r"), author: .init(login: "a"))
        XCTAssertEqual(pr.reviewKey, "u@2026-09-01T00:00:00Z")
        pr.headRefOid = "abc1234def"
        XCTAssertEqual(pr.reviewKey, "u@abc1234def")
        XCTAssertEqual(pr.versionLabel, "abc1234")
    }
}
