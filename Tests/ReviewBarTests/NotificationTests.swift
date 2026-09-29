import XCTest
@testable import ReviewBar

final class NotificationTests: XCTestCase {
    private func pr(_ n: Int, author: String = "alice") -> PR {
        PR(number: n, title: "PR \(n)", url: "https://github.com/o/r/pull/\(n)", isDraft: false,
           updatedAt: "2026-09-01T00:00:00Z", repository: .init(nameWithOwner: "o/r"), author: .init(login: author))
    }

    private func reply(_ n: Int, at: String, by: String = "bob", waiting: Int = 1) -> ReplyPR {
        ReplyPR(pr: pr(n), waiting: waiting, latestAt: at, latestBy: by)
    }

    // MARK: AlertDiff

    func testFirstRefreshIsOnlyABaseline() {
        XCTAssertTrue(AlertDiff.newRequests([pr(1), pr(2)], seen: nil).isEmpty)
        XCTAssertTrue(AlertDiff.newer([reply(1, at: "2026-09-02T00:00:00Z")], seen: nil,
                                      url: \.pr.url, latestAt: \.latestAt).isEmpty)
    }

    func testOnlyNewRequestsAlert() {
        let seen: Set<String> = [pr(1).url]
        XCTAssertEqual(AlertDiff.newRequests([pr(1), pr(2)], seen: seen).map(\.number), [2])
    }

    func testRepliesAlertOnlyWhenNewer() {
        let seen = [pr(1).url: "2026-09-02T00:00:00Z", pr(2).url: "2026-09-02T00:00:00Z"]
        let items = [reply(1, at: "2026-09-02T00:00:00Z"),   // same as before: quiet
                     reply(2, at: "2026-09-03T00:00:00Z"),   // newer reply: alert
                     reply(3, at: "2026-09-01T00:00:00Z")]   // PR not seen before: alert
        let new = AlertDiff.newer(items, seen: seen, url: \.pr.url, latestAt: \.latestAt)
        XCTAssertEqual(new.map(\.pr.number), [2, 3])
    }

    func testLatestByURLKeepsNewest() {
        let d = AlertDiff.latestByURL([reply(1, at: "2026-09-02T00:00:00Z"), reply(1, at: "2026-09-05T00:00:00Z")],
                                      url: \.pr.url, latestAt: \.latestAt)
        XCTAssertEqual(d, [pr(1).url: "2026-09-05T00:00:00Z"])
    }

    // MARK: Notification text

    func testRequestContent() {
        let c = Notifier.content(.request(pr(12, author: "priya-s")))
        XCTAssertEqual(c.title, "Review requested by priya-s")
        XCTAssertEqual(c.body, "o/r #12: PR 12")
        XCTAssertEqual(c.url, "https://github.com/o/r/pull/12")
    }

    func testReplyContent() {
        let c = Notifier.content(.reply(reply(4, at: "2026-09-02T00:00:00Z", by: "bob", waiting: 2)))
        XCTAssertEqual(c.title, "bob replied")
        XCTAssertEqual(c.body, "o/r #4: PR 4 · 2 threads waiting")
    }

    func testFeedbackContentUsesDecision() {
        let f = FeedbackPR(pr: pr(7, author: "me"), decision: "CHANGES_REQUESTED", threads: 1, reviews: 1,
                           comments: 0, latestAt: "2026-09-02T00:00:00Z", latestBy: "alice")
        let c = Notifier.content(.feedback(f))
        XCTAssertEqual(c.title, "Changes requested on your PR")
        XCTAssertEqual(c.body, "o/r #7: PR 7 · 1 thread · 1 review · alice")
    }

    /// A new reply on the same PR gets a new notification id, so it isn't silently replaced.
    func testReplyIdsDifferPerReply() {
        let a = Notifier.content(.reply(reply(4, at: "2026-09-02T00:00:00Z"))).id
        let b = Notifier.content(.reply(reply(4, at: "2026-09-03T00:00:00Z"))).id
        XCTAssertNotEqual(a, b)
    }

    func testSummaryGroupsByKind() {
        let f = FeedbackPR(pr: pr(9), decision: nil, threads: 0, reviews: 0, comments: 1,
                           latestAt: "x", latestBy: "y")
        let s = Notifier.summary([.request(pr(1)), .request(pr(2)), .reply(reply(3, at: "x")), .feedback(f)])
        XCTAssertEqual(s, "2 review requests, 1 PR with replies, 1 PR of yours with feedback")
    }
}
