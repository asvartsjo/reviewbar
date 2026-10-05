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

    /// A mention from a comment on PR `n`, linking to the comment as GitHub's notifications do.
    private func mention(_ n: Int) -> Mention {
        Mention(repo: "o/r", number: n, title: "PR \(n)", author: "someone", snippet: "",
                url: url(n) + "#issuecomment-\(n)", updatedAt: "2026-09-01T00:00:00Z")
    }

    private var turn: [ReviewingPR] { [yourTurn(1, requested: true), yourTurn(2, requested: false)] }

    @Test func everythingCountsByDefault() {
        #expect(MenuBarCount.Parts() == MenuBarCount.Parts(requests: true, reviewed: true, myPRs: true, mentions: true))
        #expect(MenuBarCount.count(yourTurn: turn, feedback: [url(3)], mentions: [mention(4)], counting: .init()) == 4)
    }

    /// Each Claude session waiting on you counts on its own, and can be left out.
    @Test func crewSessionsCountApart() {
        #expect(MenuBarCount.count(yourTurn: [], feedback: [url(3)], mentions: [], crew: ["s1", "s2"], counting: .init()) == 3)
        var noCrew = MenuBarCount.Parts(); noCrew.crew = false
        #expect(MenuBarCount.count(yourTurn: [], feedback: [url(3)], mentions: [], crew: ["s1"], counting: noCrew) == 1)
    }

    @Test func eachPartCanBeLeftOut() {
        // A different number of PRs per part, so a part counted under the wrong toggle shows.
        let turn = [yourTurn(1, requested: true), yourTurn(2, requested: true), yourTurn(3, requested: false)]
        func count(_ p: MenuBarCount.Parts) -> Int {
            MenuBarCount.count(yourTurn: turn, feedback: [url(4), url(5), url(6)],
                               mentions: [mention(7), mention(8), mention(9), mention(10)], counting: p)
        }
        #expect(count(.init(requests: true, reviewed: false, myPRs: false, mentions: false)) == 2)
        #expect(count(.init(requests: false, reviewed: true, myPRs: false, mentions: false)) == 1)
        #expect(count(.init(requests: false, reviewed: false, myPRs: true, mentions: false)) == 3)
        #expect(count(.init(requests: false, reviewed: false, myPRs: false, mentions: true)) == 4)
        #expect(count(.init(requests: false, reviewed: false, myPRs: false, mentions: false)) == 0)
    }

    @Test func aPRInSeveralPartsCountsOnce() {
        // PR 1 is a review request and also mentions you, from a comment on it.
        #expect(MenuBarCount.count(yourTurn: turn, feedback: [], mentions: [mention(1)], counting: .init()) == 2)
        // With requests off, the mention still counts it.
        #expect(MenuBarCount.count(yourTurn: turn, feedback: [], mentions: [mention(1)],
                                   counting: .init(requests: false)) == 2)
        // Two mentions on the same PR are one PR.
        #expect(MenuBarCount.count(yourTurn: [], feedback: [], mentions: [mention(5), mention(5)],
                                   counting: .init()) == 1)
    }
}
