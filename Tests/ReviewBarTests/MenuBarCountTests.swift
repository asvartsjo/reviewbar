import Testing
@testable import ReviewBar

struct MenuBarCountTests {
    private func url(_ n: Int) -> String { "https://github.com/o/r/pull/\(n)" }

    private func yourTurn(_ n: Int, requested: Bool) -> ReviewingPR {
        let pr = PR(number: n, title: "PR \(n)", url: url(n), isDraft: false,
                    updatedAt: "2026-09-01T00:00:00Z", repository: .init(nameWithOwner: "o/r"),
                    author: .init(login: "author"))
        return ReviewingPR(pr: pr, isRequested: requested, myLastReview: nil, waiting: 0, myThreads: 0,
                           resolved: 0, outdated: 0, verdicts: [], checks: nil, latestAt: pr.updatedAt)
    }

    private var turn: [ReviewingPR] { [yourTurn(1, requested: true), yourTurn(2, requested: false)] }

    @Test func everythingCountsByDefault() {
        #expect(MenuBarCount.Parts() == MenuBarCount.Parts(requests: true, reviewed: true, myPRs: true, mentions: true))
        #expect(MenuBarCount.count(yourTurn: turn, feedback: [url(3)], mentions: [url(4)], counting: .init()) == 4)
    }

    @Test func eachPartCanBeLeftOut() {
        func count(_ p: MenuBarCount.Parts) -> Int {
            MenuBarCount.count(yourTurn: turn, feedback: [url(3)], mentions: [url(4)], counting: p)
        }
        #expect(count(.init(requests: true, reviewed: false, myPRs: false, mentions: false)) == 1)
        #expect(count(.init(requests: false, reviewed: true, myPRs: false, mentions: false)) == 1)
        #expect(count(.init(requests: false, reviewed: false, myPRs: true, mentions: false)) == 1)
        #expect(count(.init(requests: false, reviewed: false, myPRs: false, mentions: true)) == 1)
        #expect(count(.init(requests: false, reviewed: false, myPRs: false, mentions: false)) == 0)
    }

    @Test func aPRInSeveralPartsCountsOnce() {
        // PR 1 is a review request and also mentions you.
        #expect(MenuBarCount.count(yourTurn: turn, feedback: [], mentions: [url(1)], counting: .init()) == 2)
        // With requests off, the mention still counts it.
        #expect(MenuBarCount.count(yourTurn: turn, feedback: [], mentions: [url(1)],
                                   counting: .init(requests: false)) == 2)
    }
}
