import Foundation
import Testing
@testable import ReviewBar

struct CrewTests {
    /// Real `claude agents --json` shapes (Claude Code 2.1.285): terminal sessions have no `id`, only
    /// `sessionId` and `pid`, plus `waitingFor` while waiting; background ones have `id` and `state`.
    private let sample = Data("""
    [
      {"pid": 1, "cwd": "/Users/me/TEACHIQ/gauss-fix", "kind": "interactive", "startedAt": 1790939000000,
       "sessionId": "aaaa1111", "name": "gauss-5b", "status": "waiting", "waitingFor": "input needed"},
      {"pid": 2, "cwd": "/Users/me/TEACHIQ/gauss", "kind": "interactive", "startedAt": 1790939100000,
       "sessionId": "bbbb2222", "name": "gauss-ef", "status": "idle"},
      {"pid": 3, "cwd": "/Users/me/TEACHIQ/gauss", "kind": "interactive", "startedAt": 1790939200000,
       "sessionId": "cccc3333", "name": "gauss-25", "status": "busy"},
      {"pid": 4, "cwd": "/Users/me/TEACHIQ/gauss", "kind": "background", "startedAt": 1790939300000,
       "sessionId": "s4", "name": "pr-4977", "status": null, "state": "blocked", "id": "dddd4444"},
      {"pid": 5, "cwd": "/Users/me/TEACHIQ/gauss", "kind": "background", "startedAt": 1790939400000,
       "sessionId": "s5", "name": "scout", "status": "busy", "state": "working", "id": "eeee5555"},
      {"pid": 6, "cwd": "/Users/me/TEACHIQ/gauss", "kind": "interactive", "startedAt": 1790939500000,
       "sessionId": "ffff6666", "name": "odd", "status": "dreaming"},
      {"pid": 7, "kind": "interactive", "status": "busy", "sessionId": "no-cwd"},
      {"pid": 8, "cwd": "/Users/me/TEACHIQ/gauss", "kind": "interactive", "status": "busy"}
    ]
    """.utf8)

    @Test func readsWorkingAndWaitingSessionsOnly() {
        let s = Crew.parseSessions(sample)
        #expect(s.map(\.id) == ["aaaa1111", "cccc3333", "dddd4444", "eeee5555", "8"])
        #expect(s.map(\.needsMe) == [true, false, true, false, false])
        #expect(s.map(\.background) == [false, false, true, true, false])
        #expect(s[0].startedAt == Date(timeIntervalSince1970: 1_790_939_000))
    }

    @Test func unreadableOutputIsNoCrew() {
        #expect(Crew.parseSessions(Data("not json".utf8)).isEmpty)
        #expect(Crew.parseSessions(Data(#"{"sessions": []}"#.utf8)).isEmpty)
    }

    private func mine(_ n: Int, branch: String, repo: String = "Teachiq/gauss") -> FeedbackPR {
        let pr = PR(number: n, title: "PR \(n)", url: "https://github.com/\(repo)/pull/\(n)", isDraft: false,
                    updatedAt: "2026-10-04T00:00:00Z", repository: .init(nameWithOwner: repo), author: .init(login: "me"))
        return FeedbackPR(pr: pr, decision: nil, threads: 0, reviews: 0, comments: 0, latestAt: "", latestBy: "",
                          branch: branch)
    }

    private let clone = "/Users/me/TEACHIQ/gauss"

    private var checkouts: [Crew.Checkout] {
        let review = TerminalApp.Worktree.forPR(4977, repo: "Teachiq/gauss", repoFolder: clone, nextToClone: true).path
        let listed: [TerminalApp.Worktree.Listed] = [
            .init(path: clone, detached: false, branch: "refs/heads/development"),
            .init(path: "/Users/me/TEACHIQ/gauss-fix", detached: false, branch: "refs/heads/atanas/fix"),
            .init(path: "\(clone)/.claude/worktrees/bright-fox", detached: false, branch: "refs/heads/worktree-bright-fox"),
            .init(path: review, detached: true),
        ]
        return Crew.checkouts(repo: "Teachiq/gauss", repoFolder: clone, listed: listed,
                              myPRs: [mine(4961, branch: "atanas/fix"), mine(9, branch: "atanas/fix", repo: "o/other")])
    }

    @Test func checkoutsKnowTheirPR() {
        #expect(checkouts.map(\.prNumber) == [nil, 4961, nil, 4977])
    }

    private func session(_ id: String, _ cwd: String, needsMe: Bool = false, started: Double = 0) -> CrewSession {
        CrewSession(id: id, name: id, cwd: cwd, background: false, needsMe: needsMe, working: !needsMe,
                    startedAt: Date(timeIntervalSince1970: started))
    }

    @Test func eachSessionLandsInTheDeepestCheckoutHoldingItsFolder() {
        let review = TerminalApp.Worktree.forPR(4977, repo: "Teachiq/gauss", repoFolder: clone, nextToClone: true).path
        let items = Crew.link([session("fix", "/Users/me/TEACHIQ/gauss-fix/server"),
                               session("review", review),
                               session("bg", "\(clone)/.claude/worktrees/bright-fox"),
                               session("clone", clone),
                               session("lookalike", "/Users/me/TEACHIQ/gauss-fixes"),
                               session("elsewhere", "/Users/me/Projects/reviewbar")], to: checkouts)
        #expect(items.map(\.session.id) == ["fix", "review", "bg", "clone"])
        #expect(items.map(\.prNumber) == [4961, 4977, nil, nil])
        #expect(Set(items.map(\.repo)) == ["Teachiq/gauss"])
    }

    @Test func waitingOnMeFirstThenNewest() {
        let items = Crew.link([session("old", clone, started: 1), session("new", clone, started: 3),
                               session("asks", clone, needsMe: true, started: 2)], to: checkouts)
        #expect(items.map(\.session.id) == ["asks", "new", "old"])
    }

    @Test func notifiesOnlyWhenASessionStartsWaiting() {
        let asks = CrewItem(session: session("a", clone, needsMe: true), repo: "Teachiq/gauss", prNumber: nil)
        let busy = CrewItem(session: session("b", clone), repo: "Teachiq/gauss", prNumber: nil)
        #expect(Crew.newlyWaiting([asks, busy], before: nil).isEmpty)          // first poll: baseline
        #expect(Crew.newlyWaiting([asks, busy], before: []).map(\.id) == ["a"])
        #expect(Crew.newlyWaiting([asks, busy], before: ["a"]).isEmpty)        // still the same question
    }

    @Test func sinceSaysTheTimeTodayAndTheDateBefore() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Stockholm")!
        let now = ISO8601DateFormatter().date(from: "2026-10-05T12:00:00Z")!
        #expect(Crew.since(ISO8601DateFormatter().date(from: "2026-10-05T07:42:00Z")!, now: now, calendar: cal) == "since 09:42")
        #expect(Crew.since(ISO8601DateFormatter().date(from: "2026-10-02T09:16:00Z")!, now: now, calendar: cal) == "since 2 Oct")
    }
}
