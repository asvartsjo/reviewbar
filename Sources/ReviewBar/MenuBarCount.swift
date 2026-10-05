import Foundation

/// What the menu bar number counts, from Settings › Menu bar number. Each part is on unless
/// turned off, so the number is the same as before until something is changed.
enum MenuBarCount {
    static let requestsKey = "badgeCountsRequests"
    static let reviewedKey = "badgeCountsReviewed"
    static let myPRsKey = "badgeCountsMyPRs"   // older single setting, kept as it was
    static let mentionsKey = "badgeCountsMentions"
    static let crewKey = "badgeCountsCrew"

    struct Parts: Equatable {
        var requests = true    // Your turn: your review is requested or re-requested
        var reviewed = true    // Your turn: new commits or replies on a PR you reviewed
        var myPRs = true       // your PRs with new feedback
        var mentions = true
        var crew = true        // Claude sessions waiting on you (Crew)

        static var current: Parts {
            func on(_ key: String) -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
            return Parts(requests: on(requestsKey), reviewed: on(reviewedKey),
                         myPRs: on(myPRsKey), mentions: on(mentionsKey), crew: on(crewKey))
        }
    }

    /// Distinct PRs from the parts that are on: a PR in several of them counts once. Mentions count
    /// by their PR's link, since theirs usually points at a comment. Each Claude session waiting on
    /// you (`crew`: session ids) counts on its own: it's a question to answer, not a PR. Pure, for tests.
    static func count(yourTurn: [ReviewingPR], feedback: [String], mentions: [Mention], crew: [String] = [],
                      counting p: Parts) -> Int {
        var urls = Set<String>()
        for r in yourTurn where r.isRequested ? p.requests : p.reviewed { urls.insert(r.pr.url) }
        if p.myPRs { urls.formUnion(feedback) }
        if p.mentions { urls.formUnion(mentions.map(\.prURL)) }
        if p.crew { urls.formUnion(crew.map { "crew:\($0)" }) }
        return urls.count
    }
}
