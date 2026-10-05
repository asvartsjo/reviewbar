import Foundation
import Testing
@testable import ReviewBar

struct MyMoveTests {
    private func mine(draft: Bool = false, decision: String? = "REVIEW_REQUIRED", threads: Int = 0,
                      reviews: Int = 0, comments: Int = 0, botThreads: Int = 0,
                      checks: String? = "SUCCESS", mergeable: String? = "MERGEABLE") -> FeedbackPR {
        let pr = PR(number: 7, title: "Mine", url: "https://github.com/o/r/pull/7", isDraft: draft,
                    updatedAt: "2026-09-11T00:00:00Z", repository: .init(nameWithOwner: "o/r"),
                    author: .init(login: "me"))
        return FeedbackPR(pr: pr, decision: decision, threads: threads, reviews: reviews, comments: comments,
                          latestAt: "", latestBy: "", checks: checks, mergeable: mergeable, botThreads: botThreads)
    }

    @Test func oneCasePerRule() {
        #expect(mine(mergeable: "CONFLICTING").move == .yours(.conflict))
        #expect(mine(checks: "FAILURE").move == .yours(.checksFailing))
        #expect(mine(checks: "ERROR").move == .yours(.checksFailing))
        #expect(mine(threads: 1).move == .yours(.feedback))
        #expect(mine(reviews: 1).move == .yours(.feedback))
        #expect(mine(comments: 1).move == .yours(.feedback))
        #expect(mine(checks: "PENDING").move == .waiting(.ci))
        #expect(mine(checks: "EXPECTED").move == .waiting(.ci))
        #expect(mine(draft: true).move == .yours(.readyForReview))
        #expect(mine(decision: "APPROVED").move == .yours(.merge))
        #expect(mine().move == .waiting(.reviewers))
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
        #expect(mine(decision: "APPROVED", checks: "PENDING").move == .waiting(.ci))
    }

    @Test func firstMatchingRuleWins() {
        #expect(mine(threads: 1, mergeable: "CONFLICTING").move == .yours(.conflict))
        #expect(mine(threads: 1, checks: "FAILURE").move == .yours(.checksFailing))
        #expect(mine(threads: 1, checks: "PENDING").move == .yours(.feedback))
        #expect(mine(draft: true, threads: 1).move == .yours(.feedback))
        #expect(mine(draft: true, checks: "PENDING").move == .waiting(.ci))
    }

    @Test func isYours() {
        #expect(mine(threads: 1).move.isYours)
        #expect(!mine().move.isYours)
    }
}

struct MyGroupTests {
    private let now = ISO8601DateFormatter().date(from: "2026-10-05T12:00:00Z")!

    private func mine(_ n: Int, draft: Bool = false, updated: String = "2026-10-04T00:00:00Z",
                      threads: Int = 0, latestAt: String = "", checks: String? = "SUCCESS",
                      mergeable: String? = "MERGEABLE") -> FeedbackPR {
        let pr = PR(number: n, title: "PR \(n)", url: "https://github.com/o/r/pull/\(n)", isDraft: draft,
                    updatedAt: updated, repository: .init(nameWithOwner: "o/r"), author: .init(login: "me"))
        return FeedbackPR(pr: pr, decision: "REVIEW_REQUIRED", threads: threads, reviews: 0, comments: 0,
                          latestAt: latestAt, latestBy: "", checks: checks, mergeable: mergeable)
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
        #expect(numbers(s) == [.oldDrafts: [1], .yours: [2], .waiting: [3]])
    }

    @Test func yourMoveMostUrgentThenWaitingLongest() {
        let s = MyGroup.sections([mine(1, draft: true),
                                  mine(2, threads: 1, latestAt: "2026-10-04T10:00:00Z"),
                                  mine(3, threads: 1, latestAt: "2026-10-02T10:00:00Z"),
                                  mine(4, mergeable: "CONFLICTING")], dismissed: [:], now: now)
        #expect(numbers(s)[.yours] == [4, 3, 2, 1])
    }

    @Test func othersMostRecentlyUpdatedFirst() {
        let s = MyGroup.sections([mine(1, updated: "2026-10-01T00:00:00Z"), mine(2, updated: "2026-10-03T00:00:00Z")],
                                 dismissed: [:], now: now)
        #expect(numbers(s)[.waiting] == [2, 1])
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
