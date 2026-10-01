import Foundation

/// What the menu bar number counts, from Settings › Menu bar number. Each part is on unless
/// turned off, so the number is the same as before until something is changed.
enum MenuBarCount {
    static let requestsKey = "badgeCountsRequests"
    static let reviewedKey = "badgeCountsReviewed"
    static let myPRsKey = "badgeCountsMyPRs"   // older single setting, kept as it was
    static let mentionsKey = "badgeCountsMentions"

    struct Parts: Equatable {
        var requests = true    // Your turn: your review is requested or re-requested
        var reviewed = true    // Your turn: new commits or replies on a PR you reviewed
        var myPRs = true       // your PRs with new feedback
        var mentions = true

        static var current: Parts {
            func on(_ key: String) -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
            return Parts(requests: on(requestsKey), reviewed: on(reviewedKey),
                         myPRs: on(myPRsKey), mentions: on(mentionsKey))
        }
    }

    /// Distinct PRs from the parts that are on: a PR in several of them counts once. Mentions count
    /// by their PR's link, since theirs usually points at a comment. Pure, for tests.
    static func count(yourTurn: [ReviewingPR], feedback: [String], mentions: [Mention], counting p: Parts) -> Int {
        var urls = Set<String>()
        for r in yourTurn where r.isRequested ? p.requests : p.reviewed { urls.insert(r.pr.url) }
        if p.myPRs { urls.formUnion(feedback) }
        if p.mentions { urls.formUnion(mentions.map(\.prURL)) }
        return urls.count
    }
}
