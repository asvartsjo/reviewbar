import Foundation
import Testing
@testable import ReviewBar

/// Feeds sample GraphQL responses (shaped like `reviewingQuery`) to `parseReviewing`, and checks
/// whose turn each PR is.
struct ReviewingTests {
    private let head = "head000"

    private func user(_ login: String, bot: Bool = false) -> String {
        #"{"login": "\#(login)", "__typename": "\#(bot ? "Bot" : "User")"}"#
    }

    private func review(_ login: String, _ state: String, at: String? = "2026-09-10T10:00:00Z",
                        commit: String? = "head000", bot: Bool = false) -> String {
        let s = at.map { "\"\($0)\"" } ?? "null"
        let c = commit.map { #"{"oid": "\#($0)"}"# } ?? "null"
        return #"{"author": \#(user(login, bot: bot)), "state": "\#(state)", "submittedAt": \#(s), "commit": \#(c)}"#
    }

    private func comment(_ login: String, _ at: String, bot: Bool = false) -> String {
        #"{"author": \#(user(login, bot: bot)), "createdAt": "\#(at)"}"#
    }

    private func thread(resolved: Bool = false, outdated: Bool = false, opener: String,
                        recent: [String]) -> String {
        """
        {"isResolved": \(resolved), "isOutdated": \(outdated),
         "opener": {"nodes": [\(comment(opener, "2026-09-01T00:00:00Z"))]},
         "recent": {"nodes": [\(recent.joined(separator: ","))]}}
        """
    }

    private func node(_ number: Int, reviews: [String] = [], threads: [String] = [],
                      checks: String? = "SUCCESS") -> String {
        let rollup = checks.map { #"{"state": "\#($0)"}"# } ?? "null"
        return """
        {"number": \(number), "title": "PR \(number)", "url": "https://github.com/o/r/pull/\(number)",
         "isDraft": false, "updatedAt": "2026-09-01T00:00:00Z", "createdAt": "2026-08-20T00:00:00Z",
         "headRefOid": "\(head)", "repository": {"nameWithOwner": "o/r"}, "author": {"login": "author"},
         "commits": {"nodes": [{"commit": {"statusCheckRollup": \(rollup)}}]},
         "reviews": {"nodes": [\(reviews.joined(separator: ","))]},
         "reviewThreads": {"nodes": [\(threads.joined(separator: ","))]}}
        """
    }

    private func parse(_ nodes: [String]) throws -> [ReviewingPR] {
        try Backend.parseReviewing(Data(
            #"{"data": {"viewer": {"login": "me"}, "search": {"nodes": [\#(nodes.joined(separator: ","))]}}}"#.utf8))
    }

    private func one(_ node: String) throws -> ReviewingPR {
        let prs = try parse([node])
        try #require(prs.count == 1)
        return prs[0]
    }

    // MARK: Whose turn

    @Test func newCommitsAfterMyApprovalAreMyTurn() throws {
        let r = try one(node(1, reviews: [review("me", "APPROVED", commit: "old1234")]))
        #expect(r.hasNewCommits)
        #expect(r.turn == .yours(.newCommits))
    }

    @Test func reviewWhoseCommitIsGoneCountsAsNewCommits() throws {
        let r = try one(node(1, reviews: [review("me", "COMMENTED", commit: nil)]))
        #expect(r.turn == .yours(.newCommits))
    }

    @Test func openThreadsAndNothingNewAreTheAuthorsTurn() throws {
        let r = try one(node(1, reviews: [review("me", "CHANGES_REQUESTED")],
                             threads: [thread(opener: "me", recent: [comment("me", "2026-09-10T10:00:00Z")])]))
        #expect(!r.hasNewCommits)
        #expect(r.turn == .authors)
    }

    @Test func verifyIsDueAfterNewCommitsOrAReply() throws {
        let mine = thread(opener: "me", recent: [comment("me", "2026-09-10T10:00:00Z")])
        let replied = thread(opener: "me", recent: [comment("author", "2026-09-11T10:00:00Z")])
        #expect(try !one(node(1, reviews: [review("me", "COMMENTED")], threads: [mine])).verifyIsDue)
        #expect(try one(node(1, reviews: [review("me", "COMMENTED", commit: "old1234")], threads: [mine])).verifyIsDue)
        #expect(try one(node(1, reviews: [review("me", "COMMENTED")], threads: [replied])).verifyIsDue)
    }

    @Test func approvedWithNothingNewIsDone() throws {
        #expect(try one(node(1, reviews: [review("me", "APPROVED")])).turn == .done)
    }

    @Test func replyInMyThreadIsMyTurnButABotReplyIsNot() throws {
        let human = thread(opener: "me", recent: [comment("me", "2026-09-10T10:00:00Z"),
                                                  comment("author", "2026-09-11T10:00:00Z")])
        let bot = thread(opener: "me", recent: [comment("me", "2026-09-10T10:00:00Z"),
                                                comment("rabbit", "2026-09-11T10:00:00Z", bot: true)])
        let mine = [review("me", "COMMENTED")]
        #expect(try one(node(1, reviews: mine, threads: [human])).turn == .yours(.reply))
        let quiet = try one(node(2, reviews: mine, threads: [bot]))
        #expect(quiet.waiting == 0)
        #expect(quiet.turn == .authors)
    }

    @Test func requestedTurnComesFromAwaitingMe() throws {
        let reviewed = try parse([node(1, reviews: [review("me", "APPROVED")])])
        let fresh = PR(number: 2, title: "PR 2", url: "https://github.com/o/r/pull/2", isDraft: false,
                       updatedAt: "2026-09-01T00:00:00Z", repository: .init(nameWithOwner: "o/r"),
                       author: .init(login: "author"))
        let merged = Backend.merge(reviewed, requested: [reviewed[0].pr, fresh])
        #expect(merged.map(\.pr.number) == [1, 2])   // each PR once
        #expect(merged[0].turn == .yours(.reRequested))
        #expect(merged[1].turn == .yours(.requested))
        #expect(Backend.merge(reviewed, requested: [])[0].turn == .done)
    }

    // MARK: List

    @Test func sectionsAreYourTurnThenAuthorsThenDoneNewestFirst() throws {
        let prs = try parse([
            node(1, reviews: [review("me", "APPROVED")]),                                          // done
            node(2, reviews: [review("me", "COMMENTED"), review("anna", "APPROVED", at: "2026-09-05T10:00:00Z")]),
            node(3, reviews: [review("me", "APPROVED", commit: "old1234")]),                       // new commits
            node(4, reviews: [review("me", "COMMENTED"), review("anna", "APPROVED", at: "2026-09-07T10:00:00Z")]),
        ])
        let sections = ReviewingPR.sections(prs)
        #expect(sections.map(\.group) == [.yours, .authors, .done])
        #expect(sections.map { $0.prs.map(\.pr.number) } == [[3], [4, 2], [1]])
        #expect(ReviewingPR.sections([]).isEmpty)
    }

    @Test func statusSaysWhyThenRepliesThreadsAndVerdicts() throws {
        let replied = thread(opener: "me", recent: [comment("me", "2026-09-10T10:00:00Z"),
                                                    comment("author", "2026-09-11T10:00:00Z")])
        let r = try one(node(1, reviews: [review("me", "COMMENTED", commit: "old1234"),
                                          review("anna", "APPROVED")],
                             threads: [replied, thread(resolved: true, opener: "me", recent: [])]))
        #expect(r.status == "New commits since your review · 1 reply waiting · 1/2 of your threads resolved · anna approved")

        let reply = try one(node(2, reviews: [review("me", "COMMENTED")], threads: [replied]))
        #expect(reply.status == "1 reply waiting · 0/1 of your threads resolved")

        #expect(try one(node(3, reviews: [review("me", "CHANGES_REQUESTED")])).status == "You requested changes")
        #expect(try one(node(4, reviews: [review("me", "APPROVED")])).status == "You approved")
    }

    // MARK: Reviews

    @Test func pendingAndDismissedReviewsOfMineAreSkipped() throws {
        let r = try one(node(1, reviews: [
            review("me", "APPROVED", at: "2026-09-10T10:00:00Z"),
            review("me", "DISMISSED", at: "2026-09-11T10:00:00Z", commit: "old1234"),
            review("me", "PENDING", at: nil, commit: "old1234"),
        ]))
        #expect(r.myLastReview?.state == "APPROVED")
        #expect(r.myLastReview?.commit == head)
    }

    @Test func verdictsLeaveOutMeTheAuthorBotsAndPlainComments() throws {
        let r = try one(node(1, reviews: [
            review("me", "APPROVED"),
            review("author", "COMMENTED"),              // a thread reply by the author
            review("rabbit", "CHANGES_REQUESTED", bot: true),
            review("bob", "COMMENTED"),
            review("carol", "CHANGES_REQUESTED"),
            review("anna", "APPROVED"),
        ]))
        #expect(r.verdicts == [.init(login: "anna", state: "APPROVED"),
                               .init(login: "carol", state: "CHANGES_REQUESTED")])
    }

    @Test func aLaterCommentKeepsAVerdictAndDismissalClearsIt() throws {
        let r = try one(node(1, reviews: [
            review("anna", "APPROVED", at: "2026-09-10T10:00:00Z"),
            review("anna", "COMMENTED", at: "2026-09-11T10:00:00Z"),
            review("carol", "CHANGES_REQUESTED", at: "2026-09-10T10:00:00Z"),
            review("carol", "DISMISSED", at: "2026-09-12T10:00:00Z"),
        ]))
        #expect(r.verdicts == [.init(login: "anna", state: "APPROVED")])
    }

    // MARK: Threads

    @Test func threadCountsAreForThreadsIOpened() throws {
        let r = try one(node(1, reviews: [review("me", "COMMENTED")], threads: [
            thread(resolved: true, outdated: true, opener: "me", recent: []),
            thread(outdated: true, opener: "me", recent: []),
            thread(opener: "me", recent: []),
            thread(resolved: true, opener: "bob", recent: []),
        ]))
        #expect(r.myThreads == 3)
        #expect(r.resolved == 1)
        #expect(r.outdated == 2)
    }

    /// Reviewing replaces Replies later, so for people (not bots) both must count the same threads.
    @Test func waitingMatchesTheRepliesRule() throws {
        let threads = [
            thread(opener: "me", recent: [comment("alice", "2026-09-02T10:00:00Z")]),                     // waiting
            thread(opener: "bob", recent: [comment("me", "2026-09-02T10:00:00Z"),
                                           comment("bob", "2026-09-03T10:00:00Z")]),                      // I replied: waiting
            thread(opener: "me", recent: [comment("alice", "2026-09-02T10:00:00Z"),
                                          comment("me", "2026-09-03T10:00:00Z")]),                        // I spoke last
            thread(resolved: true, opener: "me", recent: [comment("alice", "2026-09-02T10:00:00Z")]),     // resolved
            thread(opener: "bob", recent: [comment("alice", "2026-09-02T10:00:00Z")]),                    // not mine
        ]
        let reviewing = try one(node(1, threads: threads))
        let repliesJSON = #"{"data": {"viewer": {"login": "me"}, "search": {"nodes": [\#(node(1, threads: threads))]}}}"#
        let replies = try Backend.parseReplies(Data(repliesJSON.utf8))
        #expect(reviewing.waiting == 2)
        #expect(replies.first?.waiting == reviewing.waiting)
    }

    // MARK: Shape

    @Test func missingChecksAuthorsAndNullNodes() throws {
        let noAuthor = node(1).replacingOccurrences(of: #""author": {"login": "author"}"#, with: #""author": null"#)
        let prs = try parse([noAuthor, node(2, checks: nil), "null", "{}"])
        #expect(prs.count == 2)
        #expect(prs.first { $0.pr.number == 1 }?.pr.author.login == "ghost")
        #expect(prs.first { $0.pr.number == 2 }?.checks == nil)
    }

    @Test func newestActivityFirstAndIgnoringMyOwn() throws {
        let prs = try parse([
            node(1, reviews: [review("anna", "APPROVED", at: "2026-09-05T10:00:00Z")]),
            node(2, reviews: [review("anna", "APPROVED", at: "2026-09-06T10:00:00Z"),
                              review("me", "COMMENTED", at: "2026-09-20T10:00:00Z")]),
        ])
        #expect(prs.map(\.pr.number) == [2, 1])
        #expect(prs[0].latestAt == "2026-09-06T10:00:00Z")
    }
}
