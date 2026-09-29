import Foundation
import AppKit
import ServiceManagement
import UserNotifications

// MARK: - What is new since the last refresh

/// Something worth a notification.
enum ReviewAlert: Equatable {
    case request(PR)
    case reply(ReplyPR)
    case feedback(FeedbackPR)
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

    static func latestByURL<T>(_ items: [T], url: (T) -> String, latestAt: (T) -> String) -> [String: String] {
        Dictionary(items.map { (url($0), latestAt($0)) }, uniquingKeysWith: max)
    }
}

// MARK: - Notification settings

enum NotifySettings {
    static let requestsKey = "notifyRequests", repliesKey = "notifyReplies", feedbackKey = "notifyFeedback"

    /// On unless turned off.
    static func isOn(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    static func wants(_ alert: ReviewAlert) -> Bool {
        switch alert {
        case .request: return isOn(requestsKey)
        case .reply: return isOn(repliesKey)
        case .feedback: return isOn(feedbackKey)
        }
    }
}

// MARK: - Posting

/// macOS notifications. They need a real app bundle: under `swift run` there is none, and
/// UNUserNotificationCenter would crash, so everything here is a no-op there.
enum Notifier {
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }
    static let urlKey = "url"
    /// More than this many at once become one summary notification.
    static let maxIndividual = 3

    static func requestAuthorization() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Whether macOS allows our notifications, for the Settings hint.
    static func authorizationStatus(_ done: @escaping (UNAuthorizationStatus) -> Void) {
        guard isAvailable else { return done(.denied) }
        UNUserNotificationCenter.current().getNotificationSettings { s in
            DispatchQueue.main.async { done(s.authorizationStatus) }
        }
    }

    static func post(_ alerts: [ReviewAlert]) {
        let wanted = alerts.filter(NotifySettings.wants)
        guard isAvailable, !wanted.isEmpty else { return }
        if wanted.count > maxIndividual {
            send(id: "summary-\(UUID().uuidString)", title: "ReviewBar", body: summary(wanted), url: nil)
            return
        }
        for a in wanted {
            let c = content(a)
            send(id: c.id, title: c.title, body: c.body, url: c.url)
        }
    }

    /// Title, body and click-through URL for one alert. Pure, for tests.
    static func content(_ a: ReviewAlert) -> (id: String, title: String, body: String, url: String) {
        func line(_ pr: PR) -> String { "\(pr.repository.nameWithOwner) #\(pr.number): \(pr.title)" }
        switch a {
        case .request(let pr):
            return ("request-\(pr.url)", "Review requested by \(pr.author.login)", line(pr), pr.url)
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
        var requests = 0, replies = 0, feedback = 0
        for a in alerts {
            switch a {
            case .request: requests += 1
            case .reply: replies += 1
            case .feedback: feedback += 1
            }
        }
        func n(_ c: Int, _ one: String, _ many: String) -> String? { c == 0 ? nil : "\(c) \(c == 1 ? one : many)" }
        return [n(requests, "review request", "review requests"),
                n(replies, "PR with replies", "PRs with replies"),
                n(feedback, "PR of yours with feedback", "PRs of yours with feedback")]
            .compactMap { $0 }.joined(separator: ", ")
    }

    private static func send(id: String, title: String, body: String, url: String?) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        if let url { c.userInfo = [urlKey: url] }
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
