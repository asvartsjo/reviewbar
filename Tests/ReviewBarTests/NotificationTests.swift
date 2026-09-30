import Foundation
import Testing
@testable import ReviewBar

struct NotificationTests {
    private func pr(_ n: Int, author: String = "alice") -> PR {
        PR(number: n, title: "PR \(n)", url: "https://github.com/o/r/pull/\(n)", isDraft: false,
           updatedAt: "2026-09-01T00:00:00Z", repository: .init(nameWithOwner: "o/r"), author: .init(login: author))
    }

    private func reply(_ n: Int, at: String, by: String = "bob", waiting: Int = 1) -> ReplyPR {
        ReplyPR(pr: pr(n), waiting: waiting, latestAt: at, latestBy: by)
    }

    // MARK: AlertDiff

    @Test func firstRefreshIsOnlyABaseline() {
        #expect(AlertDiff.newRequests([pr(1), pr(2)], seen: nil).isEmpty)
        #expect(AlertDiff.newer([reply(1, at: "2026-09-02T00:00:00Z")], seen: nil,
                                url: \.pr.url, latestAt: \.latestAt).isEmpty)
    }

    @Test func onlyNewRequestsAlert() {
        let seen: Set<String> = [pr(1).url]
        #expect(AlertDiff.newRequests([pr(1), pr(2)], seen: seen).map(\.number) == [2])
    }

    @Test func repliesAlertOnlyWhenNewer() {
        let seen = [pr(1).url: "2026-09-02T00:00:00Z", pr(2).url: "2026-09-02T00:00:00Z"]
        let items = [reply(1, at: "2026-09-02T00:00:00Z"),   // same as before: quiet
                     reply(2, at: "2026-09-03T00:00:00Z"),   // newer reply: alert
                     reply(3, at: "2026-09-01T00:00:00Z")]   // PR not seen before: alert
        let new = AlertDiff.newer(items, seen: seen, url: \.pr.url, latestAt: \.latestAt)
        #expect(new.map(\.pr.number) == [2, 3])
    }

    @Test func latestByURLKeepsNewest() {
        let d = AlertDiff.latestByURL([reply(1, at: "2026-09-02T00:00:00Z"), reply(1, at: "2026-09-05T00:00:00Z")],
                                      url: \.pr.url, latestAt: \.latestAt)
        #expect(d == [pr(1).url: "2026-09-05T00:00:00Z"])
    }

    // MARK: Notification text

    @Test func requestContent() {
        let c = Notifier.content(.request(pr(12, author: "priya-s")))
        #expect(c.title == "Review requested by priya-s")
        #expect(c.body == "o/r #12: PR 12")
        #expect(c.url == "https://github.com/o/r/pull/12")
    }

    @Test func replyContent() {
        let c = Notifier.content(.reply(reply(4, at: "2026-09-02T00:00:00Z", by: "bob", waiting: 2)))
        #expect(c.title == "bob replied")
        #expect(c.body == "o/r #4: PR 4 · 2 threads waiting")
    }

    @Test func feedbackContentUsesDecision() {
        let f = FeedbackPR(pr: pr(7, author: "me"), decision: "CHANGES_REQUESTED", threads: 1, reviews: 1,
                           comments: 0, latestAt: "2026-09-02T00:00:00Z", latestBy: "alice")
        let c = Notifier.content(.feedback(f))
        #expect(c.title == "Changes requested on your PR")
        #expect(c.body == "o/r #7: PR 7 · 1 thread · 1 review · alice")
    }

    /// A new reply on the same PR gets a new notification id, so it isn't silently replaced.
    @Test func replyIdsDifferPerReply() {
        let a = Notifier.content(.reply(reply(4, at: "2026-09-02T00:00:00Z"))).id
        let b = Notifier.content(.reply(reply(4, at: "2026-09-03T00:00:00Z"))).id
        #expect(a != b)
    }

    @Test func summaryGroupsByKind() {
        let f = FeedbackPR(pr: pr(9), decision: nil, threads: 0, reviews: 0, comments: 1,
                           latestAt: "x", latestBy: "y")
        let s = Notifier.summary([.request(pr(1)), .request(pr(2)), .reply(reply(3, at: "x")), .feedback(f)])
        #expect(s == "2 review requests, 1 PR with replies, 1 PR of yours with feedback")
    }
}

struct PRFilterTests {
    private func pr(_ n: Int, draft: Bool) -> PR {
        PR(number: n, title: "PR \(n)", url: "u\(n)", isDraft: draft, updatedAt: "2026-09-01T00:00:00Z",
           repository: .init(nameWithOwner: "o/r"), author: .init(login: "a"))
    }

    @Test func draftsKeptByDefaultAndDroppedWhenOff() {
        let prs = [pr(1, draft: false), pr(2, draft: true)]
        #expect(PRFilter.others(prs, includeDrafts: true).map(\.number) == [1, 2])
        #expect(PRFilter.others(prs, includeDrafts: false).map(\.number) == [1])

        let replies = prs.map { ReplyPR(pr: $0, waiting: 1, latestAt: "x", latestBy: "b") }
        #expect(PRFilter.others(replies, includeDrafts: false).map(\.pr.number) == [1])

        let reviewing = Backend.merge([], requested: prs)
        #expect(PRFilter.others(reviewing, includeDrafts: false).map(\.pr.number) == [1])
    }

    @Test func includeDraftsDefaultsToOn() {
        let saved = UserDefaults.standard.object(forKey: PRFilter.includeDraftsKey)
        UserDefaults.standard.removeObject(forKey: PRFilter.includeDraftsKey)
        defer { if let saved { UserDefaults.standard.set(saved, forKey: PRFilter.includeDraftsKey) } }
        #expect(PRFilter.includeDrafts)
    }
}

struct MentionSnippetTests {
    @Test func snippetDropsQuotesAndFences() {
        #expect(Backend.snippet("> quoted\n\n@asvartsjo can you check this?\n```\ncode\n```")
                == "@asvartsjo can you check this? code")
    }

    @Test func snippetIsShort() {
        #expect(Backend.snippet(String(repeating: "a", count: 300)).count == 140)
    }
}
