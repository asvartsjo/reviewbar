import Foundation
import Testing
@testable import ReviewBar

/// Feeds sample GraphQL responses (shaped like `reviewingDetailQuery`) to `parseReviewingDetail`,
/// and checks the commits-since-review rule.
struct ReviewingDetailTests {
    private func user(_ login: String?, bot: Bool = false) -> String {
        login.map { #"{"login": "\#($0)", "__typename": "\#(bot ? "Bot" : "User")"}"# } ?? "null"
    }

    private func thread(_ opener: String?, last: String? = nil, lastBot: Bool = false, openerBot: Bool = false,
                        resolved: Bool = false, outdated: Bool = false, path: String = "a.ts",
                        line: Int? = 1, originalLine: Int? = nil, body: String = "Fix this") -> String {
        let lastNode = #"{"author": \#(user(last ?? opener, bot: lastBot))}"#
        return """
        {"isResolved": \(resolved), "isOutdated": \(outdated), "path": "\(path)",
         "line": \(line.map(String.init) ?? "null"), "originalLine": \(originalLine.map(String.init) ?? "null"),
         "opener": {"nodes": [{"author": \(user(opener, bot: openerBot)), "body": "\(body)", "url": "https://x/\(path)"}]},
         "recent": {"nodes": [\(lastNode)]}}
        """
    }

    private func parse(_ threads: [String]) throws -> ReviewingDetail {
        let json = #"{"data": {"viewer": {"login": "me"}, "repository": {"pullRequest": {"reviewThreads": {"nodes": [\#(threads.joined(separator: ","))]}}}}}"#
        return try Backend.parseReviewingDetail(Data(json.utf8), author: "author")
    }

    // MARK: Your threads

    @Test func myThreadStatesRepliesFirstThenOpenThenResolved() throws {
        let d = try parse([
            thread("me", resolved: true, outdated: true, path: "resolved.ts"),
            thread("me", last: "rabbit", lastBot: true, path: "bot.ts"),   // a bot reply doesn't count
            thread("me", path: "mine-last.ts"),
            thread("me", last: "author", outdated: true, path: "replied.ts"),
        ])
        #expect(d.myThreads.map(\.path) == ["replied.ts", "bot.ts", "mine-last.ts", "resolved.ts"])
        #expect(d.myThreads.map(\.state) == [.replied(by: "author"), .open, .open, .resolved])
        #expect(d.myThreads[0].stateText == "author replied · code changed")
        #expect(d.myThreads[3].stateText == "resolved · code changed")
        #expect(d.myThreads[0].url == "https://x/replied.ts")
    }

    @Test func locationFallsBackToTheOriginalLineAndSnippetDropsBold() throws {
        let d = try parse([thread("me", line: nil, originalLine: 42, body: "🟠 **MEDIUM** — a race"),
                           thread("me", path: "file-level.ts", line: nil)])
        #expect(d.myThreads[0].location == "a.ts:42")
        #expect(d.myThreads[0].snippet == "🟠 MEDIUM — a race")
        #expect(d.myThreads[1].location == "file-level.ts")
    }

    // MARK: Other reviewers

    @Test func otherOpenThreadsLeaveOutResolvedBotsTheAuthorAndGhosts() throws {
        let d = try parse([
            thread("anna"), thread("anna"), thread("anna", resolved: true),
            thread("rabbit", openerBot: true), thread("author"), thread(nil),
        ])
        #expect(d.openThreadsBy == ["anna": 2])
        #expect(d.myThreads.isEmpty)
    }

    @Test func reviewersCombineVerdictsAndOpenThreads() throws {
        let d = ReviewingDetail(myThreads: [], openThreadsBy: ["anna": 2, "bob": 1])
        let people = d.reviewers([.init(login: "anna", state: "APPROVED"), .init(login: "carol", state: "CHANGES_REQUESTED")])
        #expect(people == [.init(login: "anna", text: "approved · 2 open threads"),
                           .init(login: "bob", text: "1 open thread"),
                           .init(login: "carol", text: "requested changes")])
    }

    // MARK: Commits since your review

    private let head = "aaaaaaa1111111"

    private func review(_ commit: String?) -> ReviewingPR.MyReview {
        .init(state: "APPROVED", commit: commit, at: "2026-09-10T10:00:00Z")
    }

    private func compare(_ status: String, ahead: Int) -> Backend.CompareInfo {
        .init(status: status, aheadBy: ahead, commits: (0..<ahead).map { .init(sha: "c\($0)", message: "m\($0)") })
    }

    @Test func commitsSinceYourReview() {
        typealias C = ReviewingDetail.Commits
        #expect(C(review: nil, head: head, compare: nil) == .unknown)
        #expect(C(review: review(nil), head: head, compare: nil) == .gone)
        #expect(C(review: review(head), head: head, compare: nil) == .same)
        #expect(C(review: review("old"), head: head, compare: nil) == .unknown)   // compare failed
        #expect(C(review: review("old"), head: head, compare: compare("diverged", ahead: 2)) == .rebased)
        let ahead = C(review: review("old"), head: head, compare: compare("ahead", ahead: 2))
        #expect(ahead == .new(count: 2, commits: [.init(sha: "c0", message: "m0"), .init(sha: "c1", message: "m1")]))
        #expect(ahead.summary == "2 new commits since your review")
        #expect(C.new(count: 1, commits: []).summary == "1 new commit since your review")
    }
}
