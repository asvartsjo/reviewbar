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

    private func comment(_ login: String, _ at: String, bot: Bool = false, body: String = "") -> String {
        #"{"author": \#(user(login, bot: bot)), "createdAt": "\#(at)", "body": "\#(body)"}"#
    }

    private func thread(resolved: Bool = false, outdated: Bool = false, opener: String,
                        recent: [String]) -> String {
        """
        {"isResolved": \(resolved), "isOutdated": \(outdated),
         "opener": {"nodes": [\(comment(opener, "2026-09-01T00:00:00Z"))]},
         "recent": {"nodes": [\(recent.joined(separator: ","))]}}
        """
    }

    private func node(_ number: Int, reviews: [String] = [], viewerLatest: String = "null", comments: [String] = [],
                      threads: [String] = [], checks: String? = "SUCCESS",
                      createdAt: String = "2026-08-20T00:00:00Z", headCommittedAt: String? = nil) -> String {
        let rollup = checks.map { #"{"state": "\#($0)"}"# } ?? "null"
        let committed = headCommittedAt.map { #""\#($0)""# } ?? "null"
        return """
        {"number": \(number), "title": "PR \(number)", "url": "https://github.com/o/r/pull/\(number)",
         "isDraft": false, "updatedAt": "2026-09-01T00:00:00Z", "createdAt": "\(createdAt)",
         "headRefOid": "\(head)", "repository": {"nameWithOwner": "o/r"}, "author": {"login": "author"},
         "commits": {"nodes": [{"commit": {"committedDate": \(committed), "statusCheckRollup": \(rollup)}}]},
         "reviews": {"nodes": [\(reviews.joined(separator: ","))]}, "viewerLatestReview": \(viewerLatest),
         "comments": {"nodes": [\(comments.joined(separator: ","))]},
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

    @Test func myCommentAfterTheNewCommitsIsTheAuthorsTurn() throws {
        let r = try one(node(1, reviews: [review("me", "COMMENTED", commit: "old1234")],
                             comments: [comment("me", "2026-09-12T10:00:00Z")],
                             headCommittedAt: "2026-09-11T10:00:00Z"))
        #expect(r.hasNewCommits)
        #expect(r.turn == .authors)
    }

    @Test func myCommentBeforeTheNewCommitsLeavesThemMine() throws {
        let r = try one(node(1, reviews: [review("me", "COMMENTED", commit: "old1234")],
                             comments: [comment("me", "2026-09-10T12:00:00Z")],
                             headCommittedAt: "2026-09-11T10:00:00Z"))
        #expect(r.turn == .yours(.newCommits))
    }

    @Test func aReRequestBeatsMyComment() throws {
        var r = try one(node(1, reviews: [review("me", "COMMENTED", commit: "old1234")],
                             comments: [comment("me", "2026-09-12T10:00:00Z")],
                             headCommittedAt: "2026-09-11T10:00:00Z"))
        r.isRequested = true
        #expect(r.turn == .yours(.reRequested))
    }

    @Test func theAuthorAnsweringMyCommentIsMyTurn() throws {
        let r = try one(node(1, reviews: [review("me", "COMMENTED", commit: "old1234")],
                             comments: [comment("me", "2026-09-12T10:00:00Z"), comment("author", "2026-09-12T14:00:00Z")],
                             headCommittedAt: "2026-09-11T10:00:00Z"))
        #expect(r.turn == .yours(.authorReplied))
        #expect(r.status.hasPrefix("author replied"))
    }

    @Test func onlyTheAuthorsCommentHandsItBack() throws {
        let r = try one(node(1, reviews: [review("me", "COMMENTED")],
                             comments: [comment("lina", "2026-09-12T14:00:00Z"),
                                        comment("author", "2026-09-12T15:00:00Z", bot: true)]))
        #expect(r.turn == .authors)
    }

    @Test func theAuthorWritingToSomeoneElseLeavesItWithThem() throws {
        let r = try one(node(1, reviews: [review("me", "COMMENTED")],
                             comments: [comment("author", "2026-09-12T14:00:00Z", body: "@coderabbitai Fixed in 698090b")]))
        #expect(r.turn == .authors)
    }

    @Test func aCommentIsForYouWhenItMentionsYouOrNobody() {
        #expect(Backend.isForYou("Done, e2e numbers updated", me: "me"))
        #expect(Backend.isForYou(nil, me: "me"))
        #expect(Backend.isForYou("@Me @lina both done", me: "me"))
        #expect(!Backend.isForYou("@lina FYI", me: "me"))
        #expect(!Backend.isForYou("Thanks!\n\n@coderabbitai resolve", me: "me"))
        #expect(Backend.isForYou("Mailed someone@example.com about it", me: "me"))
    }

    @Test func theAuthorsCommentBeforeMyReviewIsAlreadySeen() throws {
        let r = try one(node(1, reviews: [review("me", "COMMENTED")],
                             comments: [comment("author", "2026-09-09T10:00:00Z")]))
        #expect(r.turn == .authors)
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

    // MARK: New since you last looked

    @Test func lastOtherAtIgnoresYouAndIsNilWithoutOthers() throws {
        let quiet = try one(node(1, reviews: [review("me", "COMMENTED", at: "2026-09-10T10:00:00Z")]))
        #expect(quiet.lastOtherAt == nil)
        let busy = try one(node(1, reviews: [review("me", "COMMENTED", at: "2026-09-12T10:00:00Z"),
                                             review("anna", "APPROVED", at: "2026-09-11T10:00:00Z")]))
        #expect(busy.lastOtherAt == "2026-09-11T10:00:00Z")
    }

    @Test func othersSpokeSinceReviewOnlyAfterMyLatestReview() throws {
        let after = try one(node(1, reviews: [review("me", "COMMENTED", at: "2026-09-10T10:00:00Z"),
                                              review("anna", "APPROVED", at: "2026-09-11T10:00:00Z")]))
        #expect(after.othersSpokeSinceReview)
        let before = try one(node(2, reviews: [review("anna", "APPROVED", at: "2026-09-11T10:00:00Z"),
                                               review("me", "COMMENTED", at: "2026-09-12T10:00:00Z")]))
        #expect(!before.othersSpokeSinceReview)
        let neverReviewed = try one(node(3, reviews: [review("anna", "APPROVED", at: "2026-09-11T10:00:00Z")]))
        #expect(!neverReviewed.othersSpokeSinceReview)
    }

    @Test func conversationCommentsCountButNotBotsOrMine() throws {
        let r = try one(node(1, reviews: [review("me", "COMMENTED", at: "2026-09-10T10:00:00Z")],
                             comments: [comment("author", "2026-09-11T10:00:00Z"),
                                        comment("coderabbitai", "2026-09-12T10:00:00Z", bot: true),
                                        comment("me", "2026-09-13T10:00:00Z")]))
        #expect(r.lastOtherAt == "2026-09-11T10:00:00Z")
        #expect(r.othersSpokeSinceReview)
    }

    @Test func changedSinceASnapshot() throws {
        let r = try one(node(1, reviews: [review("anna", "APPROVED", at: "2026-09-11T10:00:00Z")]))
        #expect(!r.changed(since: PRSnapshot(at: "2026-09-11T12:00:00Z", head: head)))
        #expect(r.changed(since: PRSnapshot(at: "2026-09-11T09:00:00Z", head: head)))      // anna after the look
        #expect(r.changed(since: PRSnapshot(at: "2026-09-11T12:00:00Z", head: "old1234")))  // pushed since
        let quiet = try one(node(2, reviews: [review("me", "COMMENTED", at: "2026-09-12T10:00:00Z")]))
        #expect(!quiet.changed(since: PRSnapshot(at: "2026-09-11T12:00:00Z", head: head)))  // your own review
    }

    @Test func snapshotsOfUnlistedPRsArePrunedAfterTheCutoff() {
        let all = ["a": PRSnapshot(at: "2026-08-01T00:00:00Z", head: nil),
                   "b": PRSnapshot(at: "2026-08-01T00:00:00Z", head: nil),
                   "c": PRSnapshot(at: "2026-09-20T00:00:00Z", head: nil)]
        let kept = PRSnapshot.pruned(all, listed: ["a"], lastListed: [:], cutoff: "2026-09-01T00:00:00Z")
        #expect(Set(kept.keys) == ["a", "c"])
    }

    /// An old snapshot of a PR that was in the list a moment ago (its repo skipped this time,
    /// or drafts hidden) stays.
    @Test func snapshotsArePrunedByWhenThePRWasLastListed() {
        let all = ["a": PRSnapshot(at: "2026-08-01T00:00:00Z", head: nil),
                   "b": PRSnapshot(at: "2026-08-01T00:00:00Z", head: nil)]
        let kept = PRSnapshot.pruned(all, listed: [], lastListed: ["a": "2026-09-30T00:00:00Z", "b": "2026-08-15T00:00:00Z"],
                                     cutoff: "2026-09-01T00:00:00Z")
        #expect(Set(kept.keys) == ["a"])
    }

    // MARK: Mute

    @Test func muteUntilSomethingChangesOrForGood() throws {
        let r = try one(node(1, reviews: [review("anna", "APPROVED", at: "2026-09-11T10:00:00Z")]))
        let before = PRSnapshot(at: "2026-09-11T09:00:00Z", head: head)
        let after = PRSnapshot(at: "2026-09-11T12:00:00Z", head: head)
        #expect(!r.isMuted(forever: false, until: nil))
        #expect(r.isMuted(forever: false, until: after))
        #expect(!r.isMuted(forever: false, until: before))                                   // anna came after
        #expect(!r.isMuted(forever: false, until: PRSnapshot(at: after.at, head: "old1234")))   // pushed since
        #expect(r.isMuted(forever: true, until: before))
    }

    @Test func aRequestMutesOnlyForGoodAndAReRequestNever() throws {
        let request = Backend.merge([], requested: [try one(node(1)).pr])[0]
        #expect(request.isRequested && request.myLastReview == nil)
        #expect(request.isMuted(forever: true, until: nil))
        #expect(!request.isMuted(forever: false, until: PRSnapshot(at: "2099-01-01T00:00:00Z", head: head)))

        let reRequest = Backend.merge(try parse([node(1, reviews: [review("me", "COMMENTED")])]),
                                      requested: [try one(node(1)).pr])[0]
        #expect(reRequest.turn == .yours(.reRequested))
        #expect(!reRequest.isMuted(forever: true, until: nil))
    }

    @Test func mutedPRsGetTheirOwnLastSection() throws {
        let prs = try parse([node(1, reviews: [review("me", "APPROVED", commit: "old1234")]),   // your turn
                             node(2, reviews: [review("me", "APPROVED", commit: "old1234")]),   // your turn, muted
                             node(3, reviews: [review("me", "APPROVED")])])                     // done
        let sections = ReviewingPR.sections(prs, muted: { $0.pr.number == 2 })
        #expect(sections.map(\.group) == [.yours, .done, .muted])
        #expect(sections.map { $0.prs.map(\.pr.number) } == [[1], [3], [2]])
    }

    @Test func stillEffectiveReplyDismissalsBecomeMutes() throws {
        let reviewing = try parse([node(1), node(2), node(3),
                                   node(4, reviews: [review("anna", "COMMENTED", at: "2026-09-10T00:00:02Z")])])
        func listed(_ n: Int) -> ReviewingPR { reviewing.first { $0.pr.number == n }! }
        func url(_ n: Int) -> String { "https://github.com/o/r/pull/\(n)" }
        func reply(_ n: Int, at: String) -> ReplyPR { ReplyPR(pr: listed(n).pr, waiting: 1, latestAt: at, latestBy: "author") }
        let dismissed = [url(1): "2026-09-10T00:00:00Z",   // hides PR 1's reply
                         url(2): "2026-09-10T00:00:00Z",   // PR 2 has a newer reply
                         url(4): "2026-09-10T00:00:00Z",   // anna's reply-review is 2 s later
                         url(9): "2026-09-10T00:00:00Z"]   // not listed
        let mutes = PRSnapshot.mutes(fromDismissed: dismissed,
                                     replies: [reply(1, at: "2026-09-10T00:00:00Z"), reply(2, at: "2026-09-11T00:00:00Z"),
                                               reply(3, at: "2026-09-10T00:00:00Z"), reply(4, at: "2026-09-10T00:00:00Z")],
                                     reviewing: reviewing)
        #expect(mutes == [url(1): PRSnapshot(at: "2026-09-10T00:00:00Z", head: head),
                          url(4): PRSnapshot(at: "2026-09-10T00:00:02Z", head: head)])
        #expect(listed(4).isMuted(forever: false, until: mutes[url(4)]))

        // Commits after your review still show: the dismissal only hid the reply.
        let pushed = try one(node(5, reviews: [review("me", "APPROVED", at: "2026-09-09T00:00:00Z", commit: "old1234")]))
        let mute = PRSnapshot.mutes(fromDismissed: [url(5): "2026-09-10T00:00:00Z"],
                                    replies: [ReplyPR(pr: pushed.pr, waiting: 1, latestAt: "2026-09-10T00:00:00Z", latestBy: "author")],
                                    reviewing: [pushed])[url(5)]
        #expect(mute?.head == "old1234")
        #expect(!pushed.isMuted(forever: false, until: mute))
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

    @Test func yourTurnPutsTheLongestOpenFirst() throws {
        let stale = [review("me", "APPROVED", commit: "old1234")]
        let prs = try parse([
            node(1, reviews: stale + [review("anna", "COMMENTED", at: "2026-09-20T10:00:00Z")],
                 createdAt: "2026-09-15T00:00:00Z"),                                   // newest activity
            node(2, reviews: stale, createdAt: "2026-09-01T00:00:00Z"),               // open longest
            node(3, reviews: stale, createdAt: "2026-09-10T00:00:00Z"),
        ])
        #expect(ReviewingPR.sections(prs).map { $0.prs.map(\.pr.number) } == [[2, 3, 1]])
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

    @Test func aDismissedOnlyReviewIsYourTurn() throws {
        let dismissed = review("me", "DISMISSED", commit: "old1234")
        for r in [try one(node(1, reviews: [dismissed])),
                  try one(node(1, viewerLatest: dismissed))] {   // the reviews window missed it
            #expect(r.turn == .yours(.dismissed))
            #expect(r.status == "Your review was dismissed")
        }
        // A review after the dismissal counts again; a pending draft alone is no dismissal.
        #expect(try one(node(2, reviews: [dismissed, review("me", "COMMENTED")])).turn == .authors)
        #expect(try one(node(3, reviews: [review("me", "PENDING", at: nil)])).turn == .authors)
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

    @Test func aReplyAfterApprovingKeepsTheApproval() throws {
        let approved = review("me", "APPROVED", at: "2026-09-10T10:00:00Z")
        let reply = review("me", "COMMENTED", at: "2026-09-11T10:00:00Z")
        for r in [try one(node(1, reviews: [approved, reply])),
                  try one(node(1, reviews: [approved, reply], viewerLatest: reply))] {
            #expect(r.myLastReview == .init(state: "APPROVED", commit: head, at: "2026-09-11T10:00:00Z"))
            #expect(r.turn == .done)
        }
    }

    @Test func myLatestReviewCountsWhenTheReviewsWindowMissesIt() throws {
        let busy = (0..<30).map { review("author", "COMMENTED", at: "2026-09-12T10:00:\(10 + $0)Z") }
        let r = try one(node(1, reviews: busy,
                             viewerLatest: review("me", "CHANGES_REQUESTED", at: "2026-09-10T10:00:00Z", commit: "old1234")))
        #expect(r.myLastReview == .init(state: "CHANGES_REQUESTED", commit: "old1234", at: "2026-09-10T10:00:00Z"))
        #expect(r.turn == .yours(.newCommits))

        // A pending or dismissed latest review leaves it to the window.
        for state in ["PENDING", "DISMISSED"] {
            let r = try one(node(1, reviews: [review("me", "APPROVED")],
                                 viewerLatest: review("me", state, commit: "old1234")))
            #expect(r.myLastReview?.state == "APPROVED", "\(state)")
        }
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

    /// Replies still drives reply notifications and the PR detail's banner, Reviewing the row
    /// and the count, so for people (not bots) both must count the same threads.
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
