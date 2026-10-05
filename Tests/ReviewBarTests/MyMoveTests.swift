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
