import Foundation
import AppKit
import ServiceManagement
import UserNotifications

// MARK: - What is new since the last refresh

/// Something worth a notification.
enum ReviewAlert: Equatable {
    case request(PR)
    /// A request on a PR you have reviewed before.
    case reRequest(PR)
    case reply(ReplyPR)
    case feedback(FeedbackPR)
    /// New commits on a PR you reviewed, after your last review.
    case pushed(ReviewingPR)
    /// The last of your threads on a PR was resolved.
    case allResolved(ReviewingPR)
    /// Someone else approved or requested changes on a PR you reviewed.
    case verdict(ReviewingPR, ReviewingPR.Verdict)
}

/// Pure comparisons between one refresh and the next. The first refresh after launch only
/// sets the baseline (callers pass `seen: nil`), so opening the app never floods you.
enum AlertDiff {
    /// Review requests that were not in the previous refresh.
    static func newRequests(_ prs: [PR], seen: Set<String>?) -> [PR] {
        guard let seen else { return [] }
        return prs.filter { !seen.contains($0.url) }
    }

    /// Items whose latest comment is newer than what the previous refresh saw for that PR.
    static func newer<T>(_ items: [T], seen: [String: String]?,
                         url: (T) -> String, latestAt: (T) -> String) -> [T] {
        guard let seen else { return [] }
        return items.filter { latestAt($0) > (seen[url($0)] ?? "") }
    }

    /// New requests, worded as re-requests for PRs in `reviewed` (URLs of PRs you've reviewed).
    static func requests(_ fresh: [PR], reviewed: Set<String>) -> [ReviewAlert] {
        fresh.map { reviewed.contains($0.url) ? .reRequest($0) : .request($0) }
    }

    /// Changes on PRs you reviewed since the previous refresh: the head moved and your review is
    /// older, your last thread got resolved, or someone's verdict is new. PRs not in `before`
    /// (such as one you just reviewed) stay quiet.
    static func reviewing(_ now: [ReviewingPR], before: [String: ReviewingPR]?) -> [ReviewAlert] {
        guard let before else { return [] }
        var alerts: [ReviewAlert] = []
        for r in now {
            guard let old = before[r.pr.url], r.myLastReview != nil else { continue }
            if r.hasNewCommits, r.pr.headRefOid != old.pr.headRefOid { alerts.append(.pushed(r)) }
            if r.myThreads > 0, r.resolved == r.myThreads, old.resolved < old.myThreads {
                alerts.append(.allResolved(r))
            }
            let was = Dictionary(old.verdicts.map { ($0.login, $0.state) }, uniquingKeysWith: { $1 })
            for v in r.verdicts where was[v.login] != v.state { alerts.append(.verdict(r, v)) }
        }
        return alerts
    }

    static func latestByURL<T>(_ items: [T], url: (T) -> String, latestAt: (T) -> String) -> [String: String] {
        Dictionary(items.map { (url($0), latestAt($0)) }, uniquingKeysWith: max)
    }
}

// MARK: - Notification settings

/// Review new review requests in the background as they arrive. Off unless turned on:
/// every review uses your Claude or ChatGPT plan.
enum AutoReview {
    static let key = "autoReview"
    static var isOn: Bool { UserDefaults.standard.bool(forKey: key) }
}

enum NotifySettings {
    static let requestsKey = "notifyRequests", repliesKey = "notifyReplies", feedbackKey = "notifyFeedback"
    static let mentionsKey = "notifyMentions"
    static let pushedKey = "notifyPushed", resolvedKey = "notifyAllResolved", verdictsKey = "notifyVerdicts"

    /// On unless turned off.
    static func isOn(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    static func wants(_ alert: ReviewAlert) -> Bool {
        switch alert {
        case .request, .reRequest: return isOn(requestsKey)
        case .reply: return isOn(repliesKey)
        case .feedback: return isOn(feedbackKey)
        case .pushed: return isOn(pushedKey)
        case .allResolved: return isOn(resolvedKey)
        case .verdict: return isOn(verdictsKey)
        }
    }
}

// MARK: - Posting

/// macOS notifications. They need a real app bundle: under `swift run` there is none, and
/// UNUserNotificationCenter would crash, so everything here is a no-op there.
enum Notifier {
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }
    static let urlKey = "url"
    /// "New commits since your review" carries a Verify fixes button (`verifyAction`).
    static let verifyCategory = "verify", verifyAction = "verify"
    /// More than this many at once become one summary notification.
    static let maxIndividual = 3

    static func requestAuthorization() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let verify = UNNotificationAction(identifier: verifyAction, title: "Verify fixes", options: [.foreground])
        UNUserNotificationCenter.current().setNotificationCategories(
            [UNNotificationCategory(identifier: verifyCategory, actions: [verify], intentIdentifiers: [])])
    }

    /// Whether macOS allows our notifications, for the Settings hint.
    static func authorizationStatus() async -> UNAuthorizationStatus {
        guard isAvailable else { return .denied }
        return await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// "@someone mentioned you" with the start of the comment. Clicking opens the comment.
    static func mention(_ m: Mention) {
        guard isAvailable, NotifySettings.isOn(NotifySettings.mentionsKey) else { return }
        send(id: "mention-\(m.url)", title: "\(m.author) mentioned you · \(m.repo) #\(m.number)",
             body: m.title + (m.snippet.isEmpty ? "" : "\n\(m.snippet)"), url: m.url)
    }

    /// "Review ready" for an automatic review, with its verdict. Clicking opens the PR.
    static func reviewReady(_ pr: PR, text: String) {
        guard isAvailable else { return }
        var verdict = "Private notes are ready in ReviewBar."
        if case .verdict(let v, let reason) = ReviewDoc.parse(text).first {
            verdict = reason.isEmpty ? v.title : "\(v.title): \(reason)"
        }
        send(id: "ready-\(pr.reviewKey)", title: "Review ready: \(pr.repository.nameWithOwner) #\(pr.number)",
             body: "\(pr.title)\n\(verdict)", url: pr.url)
    }

    static func post(_ alerts: [ReviewAlert]) {
        let wanted = alerts.filter(NotifySettings.wants)
        guard isAvailable, !wanted.isEmpty else { return }
        if wanted.count > maxIndividual {
            send(id: "summary-\(UUID().uuidString)", title: "ReviewBar", body: summary(wanted), url: nil)
            return
        }
        let verify = canVerify
        for a in wanted {
            let c = content(a)
            send(id: c.id, title: c.title, body: c.body, url: c.url, category: category(for: a, verifyAvailable: verify))
        }
    }

    /// Verify fixes would open a session: Claude, a Verify command, and a terminal the app can
    /// drive (Copy command only shows its notice in the panel, which is closed).
    private static var canVerify: Bool {
        Agent.current == .claude && ClaudeSettings.verifyCommand(for: "") != nil && TerminalApp.chosen != .copy
    }

    /// The category (action buttons) for an alert. Pure, for tests.
    static func category(for a: ReviewAlert, verifyAvailable: Bool) -> String? {
        if case .pushed = a, verifyAvailable { return verifyCategory }
        return nil
    }

    /// Title, body and click-through URL for one alert. Pure, for tests.
    static func content(_ a: ReviewAlert) -> (id: String, title: String, body: String, url: String) {
        func line(_ pr: PR) -> String { "\(pr.repository.nameWithOwner) #\(pr.number): \(pr.title)" }
        switch a {
        case .request(let pr):
            return ("request-\(pr.url)", "Review requested by \(pr.author.login)", line(pr), pr.url)
        case .reRequest(let pr):
            return ("rerequest-\(pr.url)-\(pr.updatedAt)", "Review re-requested by \(pr.author.login)", line(pr), pr.url)
        case .pushed(let r):
            return ("pushed-\(r.pr.url)-\(r.pr.headRefOid ?? "")", "New commits since your review", line(r.pr), r.pr.url)
        case .allResolved(let r):
            let threads = r.myThreads == 1 ? "1 thread" : "\(r.myThreads) threads"
            return ("resolved-\(r.pr.url)-\(r.latestAt)", "All your threads resolved", "\(line(r.pr)) · \(threads)", r.pr.url)
        case .verdict(let r, let v):
            let did = v.state == "APPROVED" ? "approved" : "requested changes"
            return ("verdict-\(r.pr.url)-\(v.login)-\(v.state)", "\(v.login) \(did)", line(r.pr), r.pr.url)
        case .reply(let r):
            let waiting = r.waiting == 1 ? "1 thread waiting" : "\(r.waiting) threads waiting"
            return ("reply-\(r.pr.url)-\(r.latestAt)", "\(r.latestBy) replied", "\(line(r.pr)) · \(waiting)", r.pr.url)
        case .feedback(let f):
            let title: String
            let noFeedback = f.threads + f.reviews + f.comments == 0
            if noFeedback && f.hasConflict {
                title = "Merge conflict on your PR"
            } else if noFeedback && f.checksFailing {
                title = "Checks failing on your PR"
            } else if noFeedback && f.readyToMerge {
                title = "Your PR is ready to merge"
            } else {
                switch f.decision {
                case "CHANGES_REQUESTED": title = "Changes requested on your PR"
                case "APPROVED": title = "Your PR was approved"
                default: title = "New feedback on your PR"
                }
            }
            return ("feedback-\(f.pr.url)-\(f.latestAt)", title, "\(line(f.pr)) · \(f.summary) · \(f.latestBy)", f.pr.url)
        }
    }

    static func summary(_ alerts: [ReviewAlert]) -> String {
        var requests = 0, replies = 0, feedback = 0, updates = 0
        for a in alerts {
            switch a {
            case .request, .reRequest: requests += 1
            case .reply: replies += 1
            case .feedback: feedback += 1
            case .pushed, .allResolved, .verdict: updates += 1
            }
        }
        func n(_ c: Int, _ one: String, _ many: String) -> String? { c == 0 ? nil : "\(c) \(c == 1 ? one : many)" }
        return [n(requests, "review request", "review requests"),
                n(replies, "PR with replies", "PRs with replies"),
                n(feedback, "PR of yours with feedback", "PRs of yours with feedback"),
                n(updates, "update on PRs you review", "updates on PRs you review")]
            .compactMap { $0 }.joined(separator: ", ")
    }

    private static func send(id: String, title: String, body: String, url: String?, category: String? = nil) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        if let url { c.userInfo = [urlKey: url] }
        if let category { c.categoryIdentifier = category }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }
}

// MARK: - Open at login

/// Login item via SMAppService. Like notifications it needs the .app bundle, ideally in /Applications.
enum LoginItem {
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

/// An @mention of you (or a team you're in) from GitHub's notifications.
struct Mention: Equatable, Identifiable {
    var id: String { url }
    let repo: String
    let number: Int
    let title: String
    let author: String
    let snippet: String
    /// The comment's page, or the PR/issue when GitHub gives no comment.
    let url: String
    let updatedAt: String
}
