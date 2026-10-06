import Foundation
import Testing
@testable import ReviewBar

/// Feeds sample GraphQL responses (shaped like `repliesQuery` / `myPRsQuery`) to the parsers.
struct FeedbackParsingTests {

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

    @Test func replyAfterMyCommentIsWaiting() throws {
        let t = thread(opener: "me", recent: [("me", "2026-09-01T10:00:00Z"), ("alice", "2026-09-02T10:00:00Z")])
        let replies = try Backend.parseReplies(repliesJSON([replyNode(1, threads: t)]))
        #expect(replies.count == 1)
        #expect(replies[0].waiting == 1)
        #expect(replies[0].latestBy == "alice")
        #expect(replies[0].latestAt == "2026-09-02T10:00:00Z")
        #expect(replies[0].pr.headRefOid == "abc1234def")
    }

    @Test func notWaitingWhenIAnsweredLastResolvedOrNotMine() throws {
        let iAnswered = thread(opener: "me", recent: [("alice", "2026-09-02T10:00:00Z"), ("me", "2026-09-03T10:00:00Z")])
        let resolved = thread(resolved: true, opener: "me", recent: [("alice", "2026-09-02T10:00:00Z")])
        let notMine = thread(opener: "bob", recent: [("bob", "2026-09-01T10:00:00Z"), ("alice", "2026-09-02T10:00:00Z")])
        let replies = try Backend.parseReplies(repliesJSON([replyNode(2, threads: [iAnswered, resolved, notMine].joined(separator: ","))]))
        #expect(replies.isEmpty)
    }

    @Test func repliesSortedNewestFirstAndCounted() throws {
        let older = thread(opener: "me", recent: [("alice", "2026-09-02T10:00:00Z")])
        let newer = thread(opener: "me", recent: [("bob", "2026-09-05T10:00:00Z")])
        let replies = try Backend.parseReplies(repliesJSON([
            replyNode(3, threads: older),
            replyNode(4, threads: [older, newer].joined(separator: ",")),
        ]))
        #expect(replies.map(\.pr.number) == [4, 3])
        #expect(replies[0].waiting == 2)
        #expect(replies[0].latestBy == "bob")
    }

    @Test func nullNodesAreSkipped() throws {
        let replies = try Backend.parseReplies(repliesJSON(["null", "{}"]))
        #expect(replies.isEmpty)
    }

    // MARK: Feedback on my own PRs

    private func user(_ login: String, bot: Bool = false) -> String {
        #"{"login": "\#(login)", "__typename": "\#(bot ? "Bot" : "User")"}"#
    }

    private func myPRsJSON(lastCommit: String = "2026-09-10T00:00:00Z", decision: String = "REVIEW_REQUIRED",
                           reviews: [String] = [], comments: [String] = [], threads: [String] = [],
                           checks: String? = nil, mergeable: String? = nil, mergeState: String? = nil,
                           branch: String? = nil) -> Data {
        let head = branch.map { "\"\($0)\"" } ?? "null"
        let rollup = checks.map { #"{"state": "\#($0)"}"# } ?? "null"
        let merge = mergeable.map { "\"\($0)\"" } ?? "null"
        let state = mergeState.map { "\"\($0)\"" } ?? "null"
        return Data("""
        {"data": {"viewer": {"login": "me"}, "search": {"nodes": [
          {"number": 7, "title": "Mine", "url": "https://github.com/o/r/pull/7", "isDraft": false,
           "createdAt": "2026-09-09T00:00:00Z", "updatedAt": "2026-09-11T00:00:00Z", "headRefOid": "fff0000", "headRefName": \(head), "reviewDecision": "\(decision)",
           "mergeable": \(merge), "mergeStateStatus": \(state),
           "reviewRequests": {"totalCount": 1},
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

    @Test func changeRequestAfterLastCommitCounts() throws {
        let prs = try Backend.parseMyPRs(myPRsJSON(
            decision: "CHANGES_REQUESTED",
            reviews: [review("alice", "CHANGES_REQUESTED", "2026-09-11T09:00:00Z")]))
        #expect(prs.count == 1)
        #expect(prs[0].reviews == 1)
        #expect(prs[0].decision == "CHANGES_REQUESTED")
        #expect(prs[0].latestBy == "alice")
        #expect(prs[0].summary == "1 review")
    }

    @Test func feedbackOlderThanMyLastCommitIsAnswered() throws {
        let prs = try Backend.parseMyPRs(myPRsJSON(
            reviews: [review("alice", "CHANGES_REQUESTED", "2026-09-09T09:00:00Z")],
            comments: [comment("bob", "2026-09-08T09:00:00Z")]))
        #expect(prs.map(\.isQuiet) == [true])
        #expect(prs.map(\.hasFeedback) == [true])   // answered, but still worth a summary
    }

    @Test func myLaterCommentCountsAsAnswer() throws {
        let prs = try Backend.parseMyPRs(myPRsJSON(
            comments: [comment("bob", "2026-09-11T09:00:00Z"), comment("me", "2026-09-11T10:00:00Z")]))
        #expect(prs.map(\.isQuiet) == [true])
    }

    @Test func botsAreIgnored() throws {
        let prs = try Backend.parseMyPRs(myPRsJSON(
            reviews: [review("coverage", "COMMENTED", "2026-09-11T09:00:00Z", body: "Coverage 91%", bot: true)],
            comments: [comment("ci", "2026-09-11T09:00:00Z", bot: true)],
            threads: [myThread(last: comment("lint", "2026-09-11T09:00:00Z", bot: true))]))
        #expect(prs.map(\.isQuiet) == [true])
        #expect(prs.map(\.hasFeedback) == [false])
    }

    /// A bot's open thread counts only for the move, never as feedback that notifies or counts.
    @Test func botThreadsAreCountedApart() throws {
        let prs = try Backend.parseMyPRs(myPRsJSON(
            threads: [myThread(last: comment("coderabbitai", "2026-09-11T09:00:00Z", bot: true)),
                      myThread(resolved: true, last: comment("coderabbitai", "2026-09-11T09:00:00Z", bot: true)),
                      myThread(last: comment("me", "2026-09-11T10:00:00Z"))],
            branch: "atanas/fix"))
        #expect(prs.map(\.botThreads) == [1])
        #expect(prs.map(\.threads) == [0])
        #expect(prs.map(\.isQuiet) == [true])
        #expect(prs.map(\.branch) == ["atanas/fix"])
        #expect(prs.map(\.lastCommitAt) == ["2026-09-10T00:00:00Z"])
        #expect(prs.map(\.move) == [.yours(.feedback)])
    }

    /// A COMMENTED review with no summary only wraps thread comments, which are counted as threads.
    @Test func emptyCommentedReviewIsNotCountedTwice() throws {
        let prs = try Backend.parseMyPRs(myPRsJSON(
            reviews: [review("alice", "COMMENTED", "2026-09-11T09:00:00Z")],
            threads: [myThread(last: comment("alice", "2026-09-11T09:00:00Z"))]))
        #expect(prs.count == 1)
        #expect(prs[0].threads == 1)
        #expect(prs[0].reviews == 0)
        #expect(prs[0].summary == "1 thread")
    }

    @Test func unresolvedThreadWaitsEvenIfOlderThanLastCommit() throws {
        let prs = try Backend.parseMyPRs(myPRsJSON(
            threads: [myThread(last: comment("alice", "2026-09-01T09:00:00Z")),
                      myThread(resolved: true, last: comment("bob", "2026-09-01T09:00:00Z")),
                      myThread(last: comment("me", "2026-09-02T09:00:00Z"))]))
        #expect(prs.count == 1)
        #expect(prs[0].threads == 1)
    }

    @Test func summaryPluralsAndOrder() throws {
        let prs = try Backend.parseMyPRs(myPRsJSON(
            reviews: [review("alice", "APPROVED", "2026-09-11T09:00:00Z")],
            comments: [comment("bob", "2026-09-11T08:00:00Z"), comment("carol", "2026-09-11T12:00:00Z")],
            threads: [myThread(last: comment("alice", "2026-09-11T07:00:00Z")),
                      myThread(last: comment("bob", "2026-09-11T06:00:00Z"))]))
        #expect(prs[0].summary == "2 threads · 1 review · 2 comments")
        #expect(prs[0].latestBy == "carol")
    }

    // MARK: CI and merge state

    /// An approval after my last push still notifies as news, but is counted apart so the move is merge.
    @Test func approvalAfterLastPushIsCountedApart() throws {
        let prs = try Backend.parseMyPRs(myPRsJSON(
            decision: "APPROVED",
            reviews: [review("simon", "APPROVED", "2026-09-11T09:00:00Z")],
            checks: "SUCCESS", mergeable: "MERGEABLE"))
        #expect(prs.map(\.reviews) == [1])
        #expect(prs.map(\.approvals) == [1])
        #expect(prs.map(\.move) == [.yours(.merge)])
    }

    @Test func approvedGreenMergeableIsListedAsReady() throws {
        let prs = try Backend.parseMyPRs(myPRsJSON(
            decision: "APPROVED",
            reviews: [review("alice", "APPROVED", "2026-09-09T09:00:00Z")],   // before last commit: no feedback
            checks: "SUCCESS", mergeable: "MERGEABLE"))
        #expect(prs.count == 1)
        #expect(prs[0].readyToMerge)
        #expect(prs[0].summary == "Ready to merge")
        #expect(prs[0].latestAt == "2026-09-09T09:00:00Z")   // the approval: stable for dismissing
        #expect(prs[0].latestBy == "alice")
    }

    @Test func approvedMergeableWithoutCIIsReady() throws {
        let prs = try Backend.parseMyPRs(myPRsJSON(
            decision: "APPROVED",
            reviews: [review("alice", "APPROVED", "2026-09-09T09:00:00Z")],
            checks: nil, mergeable: "MERGEABLE", mergeState: "CLEAN"))
        #expect(prs[0].readyToMerge)
        #expect(prs[0].latestAt == "2026-09-09T09:00:00Z")   // so it notifies once
        // A required check that never ran also leaves no checks, but GitHub blocks the merge.
        let blocked = try Backend.parseMyPRs(myPRsJSON(decision: "APPROVED", checks: nil, mergeable: "MERGEABLE",
                                                       mergeState: "BLOCKED"))
        #expect(!blocked[0].readyToMerge)
        for checks in ["PENDING", "EXPECTED", "FAILURE"] {
            let other = try Backend.parseMyPRs(myPRsJSON(decision: "APPROVED", checks: checks, mergeable: "MERGEABLE"))
            #expect(!other[0].readyToMerge)
        }
    }

    @Test func failingChecksAndConflictsAreListed() throws {
        let failing = try Backend.parseMyPRs(myPRsJSON(checks: "FAILURE", mergeable: "MERGEABLE"))
        #expect(failing.first?.status == "Checks failing")
        #expect(failing.first?.latestAt == "2026-09-10T00:00:00Z")   // the head commit
        let conflict = try Backend.parseMyPRs(myPRsJSON(checks: "SUCCESS", mergeable: "CONFLICTING"))
        #expect(conflict.first?.status == "Merge conflict")
        #expect(conflict.first?.isQuiet == false)
    }

    /// A PR nobody has looked at yet is still listed, but quiet: no time, so it never notifies.
    @Test func quietPRsAreListed() throws {
        for (checks, mergeable) in [("SUCCESS", "MERGEABLE"), ("PENDING", "UNKNOWN")] {
            let prs = try Backend.parseMyPRs(myPRsJSON(checks: checks, mergeable: mergeable))
            #expect(prs.count == 1)
            #expect(prs[0].isQuiet)
            #expect(!prs[0].hasFeedback)   // so no "Summarise feedback" box
            #expect(prs[0].latestBy == "")
            #expect(prs[0].pr.createdAt == "2026-09-09T00:00:00Z")
            #expect(AlertDiff.newer(prs, seen: [:], url: \.pr.url, latestAt: \.latestAt).isEmpty)
        }
    }

    @Test func feedbackRowsStillShowCountsWithStatus() throws {
        let prs = try Backend.parseMyPRs(myPRsJSON(
            comments: [comment("bob", "2026-09-11T09:00:00Z")], checks: "FAILURE", mergeable: "MERGEABLE"))
        #expect(prs[0].summary == "1 comment")
        #expect(prs[0].status == "Checks failing")
    }

    // MARK: Review keys

    @Test func reviewKeyUsesHeadCommitWhenKnown() {
        var pr = PR(number: 1, title: "t", url: "u", isDraft: false, updatedAt: "2026-09-01T00:00:00Z",
                    repository: .init(nameWithOwner: "o/r"), author: .init(login: "a"))
        #expect(pr.reviewKey == "u@2026-09-01T00:00:00Z")
        pr.headRefOid = "abc1234def"
        #expect(pr.reviewKey == "u@abc1234def")
        #expect(pr.versionLabel == "abc1234")
    }
}
