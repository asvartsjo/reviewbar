import Foundation
import Testing
@testable import ReviewBar

struct MyMoveTests {
    private func mine(draft: Bool = false, decision: String? = "REVIEW_REQUIRED", threads: Int = 0,
                      reviews: Int = 0, comments: Int = 0, botThreads: Int = 0,
                      checks: String? = "SUCCESS", mergeable: String? = "MERGEABLE", requested: Bool = true) -> FeedbackPR {
        let pr = PR(number: 7, title: "Mine", url: "https://github.com/o/r/pull/7", isDraft: draft,
                    updatedAt: "2026-09-11T00:00:00Z", repository: .init(nameWithOwner: "o/r"),
                    author: .init(login: "me"))
        return FeedbackPR(pr: pr, decision: decision, threads: threads, reviews: reviews, comments: comments,
                          latestAt: "", latestBy: "", checks: checks, mergeable: mergeable, botThreads: botThreads,
                          reviewersRequested: requested)
    }

    @Test func oneCasePerRule() {
        #expect(mine(mergeable: "CONFLICTING").move == .yours(.conflict))
        #expect(mine(checks: "FAILURE").move == .yours(.checksFailing))
        #expect(mine(checks: "ERROR").move == .yours(.checksFailing))
        #expect(mine(threads: 1).move == .yours(.feedback))
        #expect(mine(reviews: 1).move == .yours(.feedback))
        #expect(mine(comments: 1).move == .yours(.feedback))
        #expect(mine(checks: "PENDING").move == .yours(.checksRunning))
        #expect(mine(checks: "EXPECTED").move == .yours(.checksRunning))
        #expect(mine(draft: true).move == .yours(.readyForReview))
        #expect(mine(decision: "APPROVED").move == .yours(.merge))
        #expect(mine().move == .waiting(.reviewers))
    }

    /// A new approval is news, not something to answer: an approved green PR is ready to merge.
    @Test func newApprovalIsNotFeedback() {
        var approved = mine(decision: "APPROVED", reviews: 1); approved.approvals = 1
        #expect(approved.move == .yours(.merge))
        var mixed = mine(decision: "APPROVED", reviews: 2); mixed.approvals = 1
        #expect(mixed.move == .yours(.feedback))
    }

    @Test func codeRabbitThreadIsMyMove() {
        #expect(mine(botThreads: 2).move == .yours(.feedback))
    }

    /// Pushed and answered everything since the change request: the reviewer has to look again.
    @Test func answeredChangeRequestWaitsOnReviewer() {
        #expect(mine(decision: "CHANGES_REQUESTED").move == .waiting(.reviewers))
    }

    @Test func approvedWithoutCIIsReadyToMerge() {
        #expect(mine(decision: "APPROVED", checks: nil).move == .yours(.merge))
        #expect(mine(decision: "APPROVED", checks: "PENDING").move == .yours(.checksRunning))
        // Mine to merge before GitHub calls it CLEAN, but only CLEAN makes it ready (and notifies).
        let approved = mine(decision: "APPROVED", checks: nil)
        #expect(!approved.readyToMerge)
        #expect(approved.moveHint == "approved")
        var clean = approved; clean.mergeState = "CLEAN"
        #expect(clean.move == .yours(.merge))
        #expect(clean.readyToMerge)
        #expect(clean.moveHint == nil)
    }

    @Test func firstMatchingRuleWins() {
        #expect(mine(threads: 1, mergeable: "CONFLICTING").move == .yours(.conflict))
        #expect(mine(threads: 1, checks: "FAILURE").move == .yours(.checksFailing))
        #expect(mine(threads: 1, checks: "PENDING").move == .yours(.feedback))
        #expect(mine(draft: true, threads: 1).move == .yours(.feedback))
        #expect(mine(draft: true, checks: "PENDING").move == .yours(.readyForReview))
    }

    /// Nobody asked and nobody reviewed: my move. Asking someone sends it to waiting.
    @Test func noReviewerRequested() {
        #expect(mine(requested: false).move == .yours(.needsReviewer))
        #expect(mine(checks: "PENDING", requested: false).move == .yours(.needsReviewer))
        #expect(mine(draft: true, requested: false).move == .yours(.readyForReview))
        #expect(mine(requested: true).move == .waiting(.reviewers))
        #expect(mine(decision: "APPROVED", requested: false).move == .yours(.merge))
        #expect(mine(requested: false).move.isYours)
    }

    @Test func isYours() {
        #expect(mine(threads: 1).move.isYours)
        #expect(!mine().move.isYours)
    }
}

struct MyGroupTests {
    private let now = ISO8601DateFormatter().date(from: "2026-10-05T12:00:00Z")!

    private func mine(_ n: Int, draft: Bool = false, updated: String = "2026-10-04T00:00:00Z",
                      lastCommit: String? = nil, created: String? = nil, threads: Int = 0, latestAt: String = "",
                      checks: String? = "SUCCESS", mergeable: String? = "MERGEABLE") -> FeedbackPR {
        let pr = PR(number: n, title: "PR \(n)", url: "https://github.com/o/r/pull/\(n)", isDraft: draft,
                    updatedAt: updated, repository: .init(nameWithOwner: "o/r"), author: .init(login: "me"), createdAt: created)
        return FeedbackPR(pr: pr, decision: "REVIEW_REQUIRED", threads: threads, reviews: 0, comments: 0,
                          latestAt: latestAt, latestBy: "", checks: checks, mergeable: mergeable,
                          lastCommitAt: lastCommit)
    }

    private func numbers(_ s: [(group: MyGroup, prs: [FeedbackPR])]) -> [MyGroup: [Int]] {
        Dictionary(uniqueKeysWithValues: s.map { ($0.group, $0.prs.map(\.pr.number)) })
    }

    @Test func splitsByMoveAndLeavesOutEmptySections() {
        let s = MyGroup.sections([mine(1, threads: 1, latestAt: "2026-10-04T10:00:00Z"), mine(2)],
                                 dismissed: [:], now: now)
        #expect(s.map(\.group) == [MyGroup.yours, .waiting])
        #expect(numbers(s) == [.yours: [1], .waiting: [2]])
    }

    @Test func dismissedWaitsUntilNewFeedback() {
        let f = mine(1, threads: 1, latestAt: "2026-10-04T10:00:00Z")
        #expect(numbers(MyGroup.sections([f], dismissed: [f.pr.url: "2026-10-04T10:00:00Z"], now: now)) == [.waiting: [1]])
        #expect(numbers(MyGroup.sections([f], dismissed: [f.pr.url: "2026-10-04T09:00:00Z"], now: now)) == [.yours: [1]])
    }

    @Test func draftUntouchedThirtyDaysIsOldWhateverItsMove() {
        let s = MyGroup.sections([mine(1, draft: true, updated: "2026-09-01T00:00:00Z", threads: 1, latestAt: "2026-09-01T00:00:00Z"),
                                  mine(2, draft: true, updated: "2026-09-20T00:00:00Z"),
                                  mine(3, updated: "2026-08-01T00:00:00Z")], dismissed: [:], now: now)
        #expect(numbers(s) == [.parked: [1], .yours: [2], .waiting: [3]])
    }

    /// GitHub bumps `updatedAt` on labels and bulk edits; the last commit says when work stopped.
    @Test func oldDraftGoesByItsLastCommitNotUpdatedAt() {
        let s = MyGroup.sections([mine(1, draft: true, updated: "2026-10-04T00:00:00Z", lastCommit: "2026-07-16T00:00:00Z"),
                                  mine(2, draft: true, updated: "2026-07-16T00:00:00Z", lastCommit: "2026-10-01T00:00:00Z")],
                                 dismissed: [:], now: now)
        #expect(numbers(s) == [.parked: [1], .yours: [2]])
    }

    @Test func parkedByHandWhateverItsMoveOrDates() {
        let urgent = mine(1, threads: 1, latestAt: "2026-10-04T10:00:00Z", mergeable: "CONFLICTING")
        let s = MyGroup.sections([urgent, mine(2)], dismissed: [:], parked: [urgent.pr.url], now: now)
        #expect(numbers(s) == [.parked: [1], .waiting: [2]])
    }

    @Test func everySectionNewestCreatedFirst() {
        let s = MyGroup.sections([mine(1, created: "2026-09-28T00:00:00Z", mergeable: "CONFLICTING"),
                                  mine(2, created: "2026-10-03T00:00:00Z", threads: 1, latestAt: "2026-10-04T10:00:00Z"),
                                  mine(3, draft: true, created: "2026-10-01T00:00:00Z"),
                                  mine(4, created: "2026-09-20T00:00:00Z"),
                                  mine(5, created: "2026-10-02T00:00:00Z")], dismissed: [:], now: now)
        #expect(numbers(s)[.yours] == [2, 3, 1])
        #expect(numbers(s)[.waiting] == [5, 4])
    }

    @Test func moveHintOnlyWhereTheBadgeIsSilent() {
        var bot = mine(1); bot.botThreads = 2
        #expect(bot.moveHint == "2 bot threads")
        #expect(mine(2, draft: true).moveHint == "ready for review?")
        #expect(mine(3).moveHint == "waiting on reviewers")
        #expect(mine(4, mergeable: "CONFLICTING").moveHint == nil)
        #expect(mine(5, checks: "PENDING").moveHint == nil)
    }
}
