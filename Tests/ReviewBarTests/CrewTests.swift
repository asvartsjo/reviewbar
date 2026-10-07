import Foundation
import Testing
@testable import ReviewBar

struct CrewTests {
    /// Real `claude agents --json` shapes (Claude Code 2.1.285): terminal sessions have no `id`, only
    /// `sessionId` and `pid`, plus `waitingFor` while waiting; background ones have `id` and `state`.
    private let sample = Data("""
    [
      {"pid": 1, "cwd": "/Users/me/code/storefront-fix", "kind": "interactive", "startedAt": 1790939000000,
       "sessionId": "aaaa1111", "name": "storefront-5b", "status": "waiting", "waitingFor": "input needed"},
      {"pid": 2, "cwd": "/Users/me/code/storefront", "kind": "interactive", "startedAt": 1790939100000,
       "sessionId": "bbbb2222", "name": "storefront-ef", "status": "idle"},
      {"pid": 3, "cwd": "/Users/me/code/storefront", "kind": "interactive", "startedAt": 1790939200000,
       "sessionId": "cccc3333", "name": "storefront-25", "status": "busy"},
      {"pid": 4, "cwd": "/Users/me/code/storefront", "kind": "background", "startedAt": 1790939300000,
       "sessionId": "s4", "name": "pr-152", "status": null, "state": "blocked", "id": "dddd4444"},
      {"pid": 5, "cwd": "/Users/me/code/storefront", "kind": "background", "startedAt": 1790939400000,
       "sessionId": "s5", "name": "scout", "status": "busy", "state": "working", "id": "eeee5555"},
      {"pid": 6, "cwd": "/Users/me/code/storefront", "kind": "interactive", "startedAt": 1790939500000,
       "sessionId": "ffff6666", "name": "odd", "status": "dreaming"},
      {"pid": 7, "kind": "interactive", "status": "busy", "sessionId": "no-cwd"},
      {"pid": 8, "cwd": "/Users/me/code/storefront", "kind": "interactive", "status": "busy"}
    ]
    """.utf8)

    @Test func readsEverySessionWithAFolder() {
        let s = Crew.parseSessions(sample)
        #expect(s.map(\.id) == ["aaaa1111", "bbbb2222", "cccc3333", "dddd4444", "eeee5555", "ffff6666", "8"])
        #expect(s.map(\.needsMe) == [true, false, false, true, false, false, false])
        #expect(s.map(\.working) == [false, false, true, false, true, false, true])
        #expect(s.map(\.idle) == [false, true, false, false, false, true, false])   // "dreaming" counts as idle
        #expect(s.map(\.background) == [false, false, false, true, true, false, false])
        #expect(s[0].startedAt == Date(timeIntervalSince1970: 1_790_939_000))
        #expect(s.map(\.pid) == [1, 2, 3, 4, 5, 6, 8])   // a terminal session is stopped by its pid
    }

    @Test func unreadableOutputIsNoCrew() {
        #expect(Crew.parseSessions(Data("not json".utf8)).isEmpty)
        #expect(Crew.parseSessions(Data(#"{"sessions": []}"#.utf8)).isEmpty)
    }

    private func mine(_ n: Int, branch: String, repo: String = "acme/storefront") -> FeedbackPR {
        let pr = PR(number: n, title: "PR \(n)", url: "https://github.com/\(repo)/pull/\(n)", isDraft: false,
                    updatedAt: "2026-10-04T00:00:00Z", repository: .init(nameWithOwner: repo), author: .init(login: "me"))
        return FeedbackPR(pr: pr, decision: nil, threads: 0, reviews: 0, comments: 0, latestAt: "", latestBy: "",
                          branch: branch)
    }

    private let clone = "/Users/me/code/storefront"

    private var checkouts: [Crew.Checkout] {
        let review = TerminalApp.Worktree.forPR(152, repo: "acme/storefront", repoFolder: clone, nextToClone: true).path
        let listed: [TerminalApp.Worktree.Listed] = [
            .init(path: clone, detached: false, branch: "refs/heads/development"),
            .init(path: "/Users/me/code/storefront-fix", detached: false, branch: "refs/heads/atanas/fix"),
            .init(path: "\(clone)/.claude/worktrees/bright-fox", detached: false, branch: "refs/heads/worktree-bright-fox"),
            .init(path: review, detached: true),
        ]
        return Crew.checkouts(repo: "acme/storefront", repoFolder: clone, listed: listed,
                              myPRs: [mine(120, branch: "atanas/fix"), mine(9, branch: "atanas/fix", repo: "o/other")])
    }

    @Test func checkoutsKnowTheirPR() {
        #expect(checkouts.map(\.prNumber) == [nil, 120, nil, 152])
    }

    private func session(_ id: String, _ cwd: String, needsMe: Bool = false, started: Double = 0) -> CrewSession {
        CrewSession(id: id, name: id, cwd: cwd, background: false, needsMe: needsMe, working: !needsMe,
                    startedAt: Date(timeIntervalSince1970: started))
    }

    @Test func eachSessionLandsInTheDeepestCheckoutHoldingItsFolder() {
        let review = TerminalApp.Worktree.forPR(152, repo: "acme/storefront", repoFolder: clone, nextToClone: true).path
        let items = Crew.link([session("fix", "/Users/me/code/storefront-fix/server"),
                               session("review", review),
                               session("bg", "\(clone)/.claude/worktrees/bright-fox"),
                               session("clone", clone),
                               session("lookalike", "/Users/me/code/storefront-fixes"),
                               session("elsewhere", "/Users/me/Projects/reviewbar")], to: checkouts)
        #expect(items.map(\.session.id) == ["fix", "review", "bg", "clone"])
        #expect(items.map(\.prNumber) == [120, 152, nil, nil])
        #expect(Set(items.map(\.repo)) == ["acme/storefront"])
    }

    @Test func waitingOnMeFirstThenNewest() {
        let items = Crew.link([session("old", clone, started: 1), session("new", clone, started: 3),
                               session("asks", clone, needsMe: true, started: 2)], to: checkouts)
        #expect(items.map(\.session.id) == ["asks", "new", "old"])
    }

    @Test func notifiesOnlyWhenASessionStartsWaiting() {
        let asks = CrewItem(session: session("a", clone, needsMe: true), repo: "acme/storefront", prNumber: nil)
        let busy = CrewItem(session: session("b", clone), repo: "acme/storefront", prNumber: nil)
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

    @Test func secondSessionCheckSeesAnyStateAndFreshLaunches() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var idle = session("storefront-7a", "/Users/me/code/storefront-fix")
        idle = CrewSession(id: idle.id, name: idle.name, cwd: idle.cwd, background: false, needsMe: false,
                           working: false, startedAt: idle.startedAt)
        let crew = [CrewItem(session: idle, repo: "acme/storefront", prNumber: 120)]
        let open = Crew.openSession(onPR: 120, repo: "ACME/Storefront", crew: crew, launchedAt: nil, now: now)
        #expect(open?.contains("idle at its prompt") == true)
        #expect(open?.contains("storefront-7a") == true)
        #expect(Crew.openSession(onPR: 121, repo: "acme/storefront", crew: crew, launchedAt: nil, now: now) == nil)
        #expect(Crew.openSession(onPR: 120, repo: "o/other", crew: crew, launchedAt: nil, now: now) == nil)
        // A double click: the first session isn't listed yet.
        #expect(Crew.openSession(onPR: 121, repo: "acme/storefront", crew: crew,
                                 launchedAt: now.addingTimeInterval(-5), now: now) != nil)
        #expect(Crew.openSession(onPR: 121, repo: "acme/storefront", crew: crew,
                                 launchedAt: now.addingTimeInterval(-90), now: now) == nil)
    }

    /// Shaped like the real tree: a VS Code extension session, an iTerm2 one, and one with no known app.
    private let processes = """
        1     0 /sbin/launchd
     1241     1 /Applications/Visual Studio Code.app/Contents/MacOS/Code
    12558  1241 /Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)
    16378 12558 /Users/me/.vscode/extensions/anthropic.claude-code-2.1.287-darwin-arm64/resources/native-binary/claude
     1246     1 /Applications/iTerm.app/Contents/MacOS/iTerm2
     1324  1246 /Users/me/Library/Application Support/iTerm2/iTermServer-3.7.3
    61660  1324 /bin/zsh
    61679 61660 claude
      900     1 /usr/sbin/sshd
      901   900 claude
      700   701 claude
      701   700 /bin/zsh
    """

    @Test func readsTheProcessTableWithSpacesInPaths() {
        let t = Crew.parseProcessTable(processes)
        #expect(t[12558]?.ppid == 1241)
        #expect(t[12558]?.comm.hasSuffix("Code Helper (Plugin)") == true)
    }

    @Test func findsTheAppASessionRunsIn() {
        let t = Crew.parseProcessTable(processes)
        #expect(Crew.host(of: 16378, in: t) == .vscode)
        #expect(Crew.host(of: 61679, in: t) == .iterm)
        #expect(Crew.host(of: 901, in: t) == .other)
        #expect(Crew.host(of: 700, in: t) == .other)   // a parent loop ends, it doesn't hang
        #expect(Crew.host(of: 999, in: t) == .other)
    }

    @Test func readsTheTitleFromATranscript() {
        let transcript = """
        {"type":"user","message":{"content":"say \\"ai-title\\" here"}}
        {"type":"ai-title","aiTitle":"First guess","sessionId":"s"}
        {"type":"ai-title","aiTitle":"PR workflow and first-mate repo","sessionId":"s"}
        {"type":"custom-title","customTitle":"","sessionId":"s"}
        {"type":"ai-title", broken
        """
        let t = Crew.titles(inTranscript: Substring(transcript))
        #expect(t.ai == "PR workflow and first-mate repo")
        #expect(t.custom == nil)   // an empty /rename doesn't count
        let renamed = Crew.titles(inTranscript: #"{"type":"custom-title","customTitle":"Crew names"}"#)
        #expect(renamed.custom == "Crew names")
        #expect(Crew.titles(inTranscript: "").ai == nil)
    }

    @Test func showsTheTitleElseTheShortName() {
        let s = Crew.parseSessions(sample)
        #expect(s[1].sessionId == "bbbb2222")
        #expect(s[3].sessionId == "s4")   // agent view sessions have one too, beside their `id`
        #expect(s[1].displayName == "storefront-ef")
        var titled = s[1]
        titled.title = "Bearing skill usage"
        #expect(titled.displayName == "Bearing skill usage")
    }
}
