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

    private func parse(_ threads: [String] = [], reviews: [String] = [], timeline: [String] = [],
                       since: String? = nil) throws -> ReviewingDetail {
        let json = """
        {"data": {"viewer": {"login": "me"}, "repository": {"pullRequest": {
          "reviewThreads": {"nodes": [\(threads.joined(separator: ","))]},
          "reviews": {"nodes": [\(reviews.joined(separator: ","))]},
          "timelineItems": {"nodes": [\(timeline.joined(separator: ","))]}}}}}
        """
        return try Backend.parseReviewingDetail(Data(json.utf8), author: "author", since: since)
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

    /// A severity-tagged comment's shape: a title line, then paragraphs and a code block. JSON-escaped.
    private let skillComment = #"🟡 **LOW** — Logic in the controller\r\n\r\n**Description:** Move it.\r\n\r\n"#
        + #"**Suggested fix:** An Action.\r\n```php\r\nnew Action();\r\n```"#

    @Test func snippetIsTheTitleAndTooltipDropsCode() throws {
        let d = try parse([thread("me", body: skillComment)])
        #expect(d.myThreads[0].snippet == "🟡 LOW — Logic in the controller")
        #expect(d.myThreads[0].fullText
                == "🟡 LOW — Logic in the controller\n\nDescription: Move it.\n\nSuggested fix: An Action.")
    }

    @Test func severityFromTheLeadingIcon() {
        typealias S = ReviewingDetail.MyThread.Severity
        #expect(S(title: "🚨 SEVERE — x") == .severe)
        #expect(S(title: "🔴 HIGH — x") == .high)
        #expect(S(title: "🟠 MEDIUM — x") == .medium)
        #expect(S(title: "🟡 LOW — x") == .low)
        #expect(S(title: "❓ Open question — x") == .question)
        #expect(S(title: "❓\u{FE0F} Open question — x") == .question)
        #expect(S(title: "Fix this 🔴") == nil)
        #expect(S(title: "") == nil)
        #expect(S.allCases.filter(\.isBlocking) == [.severe, .high])
    }

    @Test func titleDropsTheSeverityIcon() throws {
        let d = try parse([
            thread("me", path: "a.ts", body: "🔴 **HIGH** — Totals"),
            thread("me", path: "b.ts", body: "❓\u{FE0F} Open question — x"),
            thread("me", path: "c.ts", body: "Fix this 🔴"),
            thread("me", path: "d.ts", body: "🔴1 thing"),
        ])
        #expect(d.myThreads.first { $0.path == "a.ts" }?.title == "HIGH — Totals")
        #expect(d.myThreads.first { $0.path == "b.ts" }?.title == "Open question — x")
        #expect(d.myThreads.first { $0.path == "c.ts" }?.title == "Fix this 🔴")
        #expect(d.myThreads.first { $0.path == "d.ts" }?.title == "1 thing")
    }

    @Test func threadsSortBySeverityWithinEachState() throws {
        let d = try parse([
            thread("me", path: "plain.ts", body: "Fix this"),
            thread("me", path: "low.ts", body: "🟡 **LOW** — x"),
            thread("me", resolved: true, path: "resolved-high.ts", body: "🔴 **HIGH** — x"),
            thread("me", path: "high.ts", body: "🔴 **HIGH** — x"),
            thread("me", last: "author", path: "replied-low.ts", body: "🟡 **LOW** — x"),
        ])
        #expect(d.myThreads.map(\.path) == ["replied-low.ts", "high.ts", "low.ts", "plain.ts", "resolved-high.ts"])
    }

    @Test func headerCountsOnlyOpenThreadsAndBlockingOnes() throws {
        let d = try parse([
            thread("me", body: "🟡 **LOW** — x"),
            thread("me", last: "author", body: "❓ **Open question** — x"),
            thread("me", body: "🔴 **HIGH** — x"),
            thread("me", resolved: true, body: "🚨 **SEVERE** — x"),
            thread("me", body: "Fix this"),
        ])
        #expect(d.openBySeverity.map(\.severity) == [.high, .low, .question])
        #expect(d.openBySeverity.map(\.count) == [1, 1, 1])
        #expect(d.blockingOpen == 1)

        let plain = try parse([thread("me"), thread("me", resolved: true, body: "🔴 **HIGH** — x")])
        #expect(plain.openBySeverity.isEmpty)
        #expect(plain.blockingOpen == 0)
    }

    @Test func titleSkipsQuotesAndBlankLines() {
        #expect(Backend.threadTitle("\n> quoted\n\nReal title\nmore") == "Real title")
        #expect(Backend.threadTitle(String(repeating: "a", count: 300)).count == 140)
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

    // MARK: Activity since your review

    private let since = "2026-09-24T18:43:32Z"

    /// `replies` of the `comments` answer existing threads.
    private func review(_ login: String, _ state: String, at: String, comments: Int = 0, replies: Int = 0,
                        bot: Bool = false) -> String {
        let nodes = (0..<comments).map { $0 < replies ? #"{"replyTo": {"id": "c"}}"# : #"{"replyTo": null}"# }
        return """
        {"author": \(user(login, bot: bot)), "state": "\(state)", "submittedAt": "\(at)", "url": "https://x/r-\(at)",
         "comments": {"totalCount": \(comments), "nodes": [\(nodes.joined(separator: ","))]}}
        """
    }

    private func event(_ type: String, _ login: String, at: String, bot: Bool = false, extra: String = "") -> String {
        let who = type == "IssueComment" ? "author" : "actor"
        return #"{"__typename": "\#(type)", "\#(who)": \#(user(login, bot: bot)), "createdAt": "\#(at)"\#(extra)}"#
    }

    @Test func activityIsNewestFirstAndOnlyAfterYourReview() throws {
        let d = try parse(reviews: [
            review("anna", "APPROVED", at: "2026-09-20T10:00:00Z"),                  // before your review
            review("anna", "APPROVED", at: "2026-09-25T10:00:00Z"),
            review("bob", "CHANGES_REQUESTED", at: "2026-09-26T10:00:00Z", comments: 3),
            review("carol", "COMMENTED", at: "2026-09-27T10:00:00Z", comments: 2, replies: 1),
            review("dave", "COMMENTED", at: "2026-09-27T11:00:00Z"),
        ], timeline: [
            event("IssueComment", "author", at: "2026-09-28T10:00:00Z", extra: #", "url": "https://x/c""#),
            event("HeadRefForcePushedEvent", "author", at: "2026-09-29T10:00:00Z"),
        ], since: since)
        #expect(d.activity.map(\.text) == [
            "author force-pushed", "author commented on the PR", "dave commented in a review",
            "carol reviewed · 2 comments", "bob requested changes · 3 comments", "anna approved",
        ])
        #expect(d.activity[0].url == nil)
        #expect(d.activity[1].url == "https://x/c")
        #expect(!d.activityCapped)
    }

    @Test func forcePushesInARowAreMergedToo() throws {
        let d = try parse(timeline: [
            event("HeadRefForcePushedEvent", "author", at: "2026-09-25T10:00:00Z"),
            event("HeadRefForcePushedEvent", "author", at: "2026-09-25T11:00:00Z"),
            event("IssueComment", "author", at: "2026-09-25T12:00:00Z"),
            event("HeadRefForcePushedEvent", "author", at: "2026-09-25T13:00:00Z"),
            event("HeadRefForcePushedEvent", "author", at: "2026-09-25T14:00:00Z"),
            event("HeadRefForcePushedEvent", "author", at: "2026-09-25T15:00:00Z"),
        ], since: since)
        #expect(d.activity.map(\.text) == ["author force-pushed 3 times", "author commented on the PR",
                                           "author force-pushed 2 times"])
    }

    @Test func threadRepliesAreMergedPerPersonInARow() throws {
        let d = try parse(reviews: [
            review("simon", "COMMENTED", at: "2026-09-25T10:00:00Z", comments: 1, replies: 1),
            review("simon", "COMMENTED", at: "2026-09-25T10:01:00Z", comments: 1, replies: 1),
            review("setn", "COMMENTED", at: "2026-09-25T10:02:00Z", comments: 1, replies: 1),
            review("simon", "COMMENTED", at: "2026-09-25T10:03:00Z", comments: 1, replies: 1),
            review("simon", "COMMENTED", at: "2026-09-25T10:04:00Z", comments: 1, replies: 1),
        ], since: since)
        #expect(d.activity.map(\.text) == ["simon replied in 2 threads", "setn replied in 1 thread",
                                           "simon replied in 2 threads"])
        #expect(d.activity[0].at == "2026-09-25T10:04:00Z")   // the newest of the merged ones
    }

    @Test func activityLeavesOutYouAndBots() throws {
        let d = try parse(reviews: [
            review("me", "COMMENTED", at: "2026-09-25T10:00:00Z", comments: 1, replies: 1),
            review("coderabbitai", "COMMENTED", at: "2026-09-25T11:00:00Z", comments: 4, bot: true),
        ], timeline: [
            event("IssueComment", "coderabbitai", at: "2026-09-25T12:00:00Z", bot: true),
            event("HeadRefForcePushedEvent", "me", at: "2026-09-25T13:00:00Z"),
        ], since: since)
        #expect(d.activity.isEmpty)
    }

    @Test func requestsAndDismissalsSayWhenTheyAreAboutYou() throws {
        let d = try parse(timeline: [
            event("ReviewRequestedEvent", "author", at: "2026-09-25T10:00:00Z",
                  extra: #", "requestedReviewer": {"login": "me"}"#),
            event("ReviewRequestedEvent", "author", at: "2026-09-25T11:00:00Z",
                  extra: #", "requestedReviewer": {"name": "backend"}"#),
            event("ReviewDismissedEvent", "author", at: "2026-09-25T12:00:00Z",
                  extra: #", "review": {"author": {"login": "me"}}"#),
            event("ReviewDismissedEvent", "author", at: "2026-09-25T13:00:00Z",
                  extra: #", "review": {"author": {"login": "anna"}}"#),
            event("ConvertToDraftEvent", "author", at: "2026-09-25T14:00:00Z"),
            event("ReadyForReviewEvent", "author", at: "2026-09-25T15:00:00Z"),
        ], since: since)
        #expect(d.activity.map(\.text) == [
            "author marked it ready for review", "author converted it to a draft",
            "author dismissed anna's review", "author dismissed your review",
            "author requested a review from backend", "author requested your review",
        ])
    }

    @Test func aFullPageAfterYourReviewIsCapped() throws {
        let full = (0..<Backend.activityLimit).map {
            review("anna", "COMMENTED", at: String(format: "2026-09-25T10:%02d:00Z", $0), comments: 1)
        }
        #expect(try parse(reviews: full, since: since).activityCapped)
        // The same page reaching back before your review has everything since.
        let reaching = [review("anna", "APPROVED", at: "2026-09-01T10:00:00Z")] + full.dropFirst()
        #expect(try !parse(reviews: reaching, since: since).activityCapped)
    }

    @Test func noActivityWithoutAReview() throws {
        let d = try parse(reviews: [review("anna", "APPROVED", at: "2026-09-25T10:00:00Z")])
        #expect(d.activity.isEmpty)
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
