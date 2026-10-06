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

    // MARK: PRs you review

    /// PR 5, reviewed by you at commit "c1" unless `reviewedAt` is nil (never reviewed).
    private func reviewing(head: String = "c1", reviewedAt: String? = "c1", threads: Int = 0, resolved: Int = 0,
                           verdicts: [(String, String)] = [], latestAt: String = "t1") -> ReviewingPR {
        var p = pr(5)
        p.headRefOid = head
        return ReviewingPR(pr: p, myLastReview: reviewedAt.map { .init(state: "COMMENTED", commit: $0, at: "t0") },
                           waiting: 0, myThreads: threads, resolved: resolved, outdated: 0,
                           verdicts: verdicts.map { .init(login: $0.0, state: $0.1) }, checks: nil, latestAt: latestAt)
    }

    private func diff(_ before: ReviewingPR?, _ now: ReviewingPR) -> [ReviewAlert] {
        AlertDiff.reviewing([now], before: before.map { [$0.pr.url: $0] } ?? [:])
    }

    @Test func reviewingIsQuietOnBaselineAndForNewPRs() {
        #expect(AlertDiff.reviewing([reviewing(head: "c2")], before: nil).isEmpty)
        #expect(diff(nil, reviewing(head: "c2", threads: 1, resolved: 1, verdicts: [("anna", "APPROVED")])).isEmpty)
    }

    @Test func newHeadAfterYourReviewAlertsOnce() {
        let pushed = reviewing(head: "c2")
        #expect(diff(reviewing(), pushed) == [.pushed(pushed)])
        #expect(diff(pushed, pushed).isEmpty)                                   // same head next refresh
        #expect(diff(reviewing(), reviewing(head: "c2", reviewedAt: "c2")).isEmpty)   // you reviewed the new head
        #expect(diff(reviewing(reviewedAt: nil), reviewing(head: "c2", reviewedAt: nil)).isEmpty)   // never reviewed
    }

    @Test func lastThreadResolvedAlerts() {
        let done = reviewing(threads: 2, resolved: 2)
        #expect(diff(reviewing(threads: 2, resolved: 1), done) == [.allResolved(done)])
        #expect(diff(done, done).isEmpty)
        #expect(diff(reviewing(threads: 3, resolved: 1), reviewing(threads: 3, resolved: 2)).isEmpty)
    }

    @Test func newOrChangedVerdictsAlert() {
        let before = reviewing(verdicts: [("anna", "CHANGES_REQUESTED"), ("bob", "APPROVED")])
        let now = reviewing(verdicts: [("anna", "APPROVED"), ("bob", "APPROVED"), ("cara", "CHANGES_REQUESTED")])
        #expect(diff(before, now) == [.verdict(now, .init(login: "anna", state: "APPROVED")),
                                      .verdict(now, .init(login: "cara", state: "CHANGES_REQUESTED"))])
    }

    /// A request you hadn't reviewed is listed without verdicts, so your first review would
    /// otherwise announce every earlier one.
    @Test func yourFirstReviewDoesntAnnounceOlderVerdicts() {
        let requested = reviewing(reviewedAt: nil)
        #expect(diff(requested, reviewing(head: "c2", verdicts: [("anna", "APPROVED")])).isEmpty)
    }

    @Test func requestOnAReviewedPRIsARerequest() {
        #expect(AlertDiff.requests([pr(1), pr(2)], reviewed: [pr(2).url]) == [.request(pr(1)), .reRequest(pr(2))])
        #expect(Notifier.content(.reRequest(pr(2, author: "priya-s"))).title == "Review re-requested by priya-s")
    }

    @Test func reviewingContent() {
        let r = reviewing(head: "c2", threads: 3, resolved: 3)
        #expect(Notifier.content(.pushed(r)).title == "New commits since your review")
        #expect(Notifier.content(.pushed(r)).body == "o/r #5: PR 5")
        #expect(Notifier.content(.allResolved(r)).body == "o/r #5: PR 5 · 3 threads")
        #expect(Notifier.content(.verdict(r, .init(login: "anna", state: "CHANGES_REQUESTED"))).title
                == "anna requested changes")
        #expect(Notifier.content(.pushed(r)).id != Notifier.content(.pushed(reviewing(head: "c3"))).id)
    }

    @Test func onlyNewCommitsGetTheVerifyButton() {
        let r = reviewing(head: "c2")
        #expect(Notifier.category(for: .pushed(r), verifyAvailable: true) == Notifier.verifyCategory)
        #expect(Notifier.category(for: .pushed(r), verifyAvailable: false) == nil)
        #expect(Notifier.category(for: .allResolved(r), verifyAvailable: true) == nil)
        #expect(Notifier.category(for: .reply(reply(5, at: "x")), verifyAvailable: true) == nil)
        #expect(Notifier.category(for: .request(pr(5)), verifyAvailable: true) == nil)
    }

    @Test func summaryCountsReviewingUpdates() {
        let r = reviewing()
        let s = Notifier.summary([.reRequest(pr(1)), .pushed(r), .allResolved(r),
                                  .verdict(r, .init(login: "anna", state: "APPROVED"))])
        #expect(s == "1 review request, 3 updates on PRs you review")
    }

    // MARK: One notification per PR

    @Test func alertsOnOnePRBecomeOneGroupRequestFirst() {
        let r = reviewing(head: "c2")
        let anna = ReviewAlert.verdict(r, .init(login: "anna", state: "APPROVED"))
        let bob = ReviewAlert.verdict(r, .init(login: "bob", state: "CHANGES_REQUESTED"))
        let other = ReviewAlert.request(pr(6))
        let groups = Notifier.grouped([.allResolved(r), anna, other, .pushed(r), bob, .reRequest(pr(5))])
        #expect(groups == [[.reRequest(pr(5)), .pushed(r), anna, bob, .allResolved(r)], [other]])
    }

    @Test func groupContentUsesTheTopAlertAndListsTheRest() {
        let r = reviewing(head: "c2", threads: 2, resolved: 2)
        let group: [ReviewAlert] = [.reRequest(pr(5, author: "priya-s")), .pushed(r),
                                    .verdict(r, .init(login: "anna", state: "APPROVED"))]
        let c = Notifier.content(group)
        let top = Notifier.content(group[0])
        #expect(c.title == "Review re-requested by priya-s")
        #expect(c.body == "o/r #5: PR 5\nNew commits since your review\nanna approved")
        #expect(c.id == top.id)
        #expect(c.url == top.url)
        #expect(Notifier.content([.pushed(r)]) == Notifier.content(.pushed(r)))
    }

    @Test func groupKeepsVerifyButtonWhenItHasNewCommits() {
        let r = reviewing(head: "c2")
        #expect(Notifier.category(for: [.reRequest(pr(5)), .pushed(r)], verifyAvailable: true) == Notifier.verifyCategory)
        #expect(Notifier.category(for: [.reRequest(pr(5)), .pushed(r)], verifyAvailable: false) == nil)
        #expect(Notifier.category(for: [.reRequest(pr(5)), .allResolved(r)], verifyAvailable: true) == nil)
    }
}

struct PRFilterTests {
    private func pr(_ n: Int, draft: Bool) -> PR {
        PR(number: n, title: "PR \(n)", url: "u\(n)", isDraft: draft, updatedAt: "2026-09-01T00:00:00Z",
           repository: .init(nameWithOwner: "o/r"), author: .init(login: "a"))
    }

    @Test func requestsGetHeadCommitAndCI() {
        let json = #"{"data": {"p0": {"headRefOid": "abc", "commits": {"nodes": [{"commit": {"statusCheckRollup": {"state": "FAILURE"}}}]}},"#
            + #" "p1": {"headRefOid": "def", "commits": {"nodes": [{"commit": {"statusCheckRollup": null}}]}}, "p2": null}}"#
        let prs = Backend.applyHeadCommits([pr(1, draft: false), pr(2, draft: false), pr(3, draft: false)], Data(json.utf8))
        #expect(prs.map(\.headRefOid) == ["abc", "def", nil])
        #expect(prs.map(\.checks) == ["FAILURE", nil, nil])
        #expect(Backend.merge([], requested: prs).map(\.checks) == ["FAILURE", nil, nil])
        #expect(Backend.applyHeadCommits([pr(1, draft: false)], Data("oops".utf8)) == [pr(1, draft: false)])
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

    @Test func ownCommentIsNotAMention() {
        #expect(!Backend.isMention("Thanks @atanasfn, fixed", author: "atanasfn", me: "AtanasFN", team: false))
    }

    @Test func latestCommentMustMentionYou() {
        #expect(Backend.isMention("@atanasfn can you check?", author: "lina", me: "atanasfn", team: false))
        #expect(!Backend.isMention("Re-checked, all good", author: "lina", me: "atanasfn", team: false))
        #expect(!Backend.isMention("mail me at x@atanasfn.se", author: "lina", me: "atanasfn", team: false))
        #expect(!Backend.isMention(nil, author: "lina", me: "atanasfn", team: false))
    }

    @Test func yourReplyDoesNotHideTheMention() {
        let mention = Backend.MentionPost(author: "carol", body: "@atanasfn kan du kolla?", url: "u1", at: "2026-10-06T08:37:35Z")
        let reply = Backend.MentionPost(author: "atanasfn", body: "@carol tack", url: "u2", at: "2026-10-06T09:00:00Z")
        #expect(Backend.newestMention(in: [mention, reply], me: "atanasfn", team: false, since: "2026-09-29T00:00:00Z") == mention)
    }

    @Test func mentionOlderThanSinceIsGone() {
        let old = Backend.MentionPost(author: "omar", body: "@atanasfn ?", url: "u", at: "2026-09-04T07:10:40Z")
        let comment = Backend.MentionPost(author: "carol", body: "Fixed", url: "u2", at: "2026-10-06T08:40:00Z")
        #expect(Backend.newestMention(in: [old, comment], me: "atanasfn", team: false, since: "2026-09-29T00:00:00Z") == nil)
    }

    @Test func newestMentionWins() {
        let a = Backend.MentionPost(author: "lina", body: "@atanasfn one", url: "a", at: "2026-10-01T10:00:00Z")
        let b = Backend.MentionPost(author: "omar", body: "@atanasfn two", url: "b", at: "2026-10-02T10:00:00Z")
        #expect(Backend.newestMention(in: [b, a], me: "atanasfn", team: false, since: "2026-09-29T00:00:00Z") == b)
    }

    @Test func teamMentionNeedsATeamHandle() {
        #expect(Backend.isMention("@Teachiq/frontend please look", author: "lina", me: "atanasfn", team: true))
        #expect(!Backend.isMention("@lina please look", author: "lina", me: "atanasfn", team: true))
    }

    @Test func teamHandleIsNotAPersonalMention() {
        #expect(!Backend.isMention("@Teachiq/frontend please look", author: "lina", me: "atanasfn", team: false))
    }

    @Test func quotedOrCodeMentionIsNotANewOne() {
        #expect(!Backend.isMention("> @atanasfn can you check?\n\nDone", author: "lina", me: "atanasfn", team: false))
        #expect(!Backend.isMention("```\n@atanasfn\n```", author: "lina", me: "atanasfn", team: false))
        #expect(!Backend.isMention("Ping `@atanasfn` in the docs", author: "lina", me: "atanasfn", team: false))
        #expect(Backend.isMention("> old\n\n@atanasfn now this", author: "lina", me: "atanasfn", team: false))
    }

    @Test func quoteReplyKeepsTheOriginalMention() {
        let mention = Backend.MentionPost(author: "carol", body: "@atanasfn kan du kolla?", url: "u1", at: "2026-10-05T08:00:00Z")
        let quote = Backend.MentionPost(author: "lina", body: "> @atanasfn kan du kolla?\n\nSame here", url: "u2", at: "2026-10-06T09:00:00Z")
        #expect(Backend.newestMention(in: [mention, quote], me: "atanasfn", team: false, since: "2026-09-29T00:00:00Z") == mention)
    }
}
