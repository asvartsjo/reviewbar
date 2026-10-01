import Foundation

enum PRFilter {
    static let includeDraftsKey = "includeDrafts"

    /// On unless turned off in Settings.
    static var includeDrafts: Bool {
        UserDefaults.standard.object(forKey: includeDraftsKey) as? Bool ?? true
    }

    /// Other people's PRs (review requests, replies). Your own drafts are never hidden. Pure, for tests.
    static func others(_ prs: [PR], includeDrafts: Bool) -> [PR] {
        includeDrafts ? prs : prs.filter { !$0.isDraft }
    }

    static func others(_ replies: [ReplyPR], includeDrafts: Bool) -> [ReplyPR] {
        includeDrafts ? replies : replies.filter { !$0.pr.isDraft }
    }

    static func others(_ reviewing: [ReviewingPR], includeDrafts: Bool) -> [ReviewingPR] {
        includeDrafts ? reviewing : reviewing.filter { !$0.pr.isDraft }
    }
}
