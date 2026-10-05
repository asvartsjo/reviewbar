import Foundation

/// Whose move it is on one of my open PRs: mine (and why), or someone else's.
/// Follows the rule table in the `bearings` skill (`~/.claude/skills/bearings/SKILL.md`).
enum MyMove: Equatable {
    case yours(Reason)
    case waiting(On)

    enum Reason: Equatable {
        case conflict
        case checksFailing
        /// Unanswered reviewer feedback, or a bot's (CodeRabbit's) open thread.
        case feedback
        /// A draft with nothing else to do: time to mark it ready?
        case readyForReview
        case merge
    }

    enum On: Equatable { case ci, reviewers }

    var isYours: Bool { if case .yours = self { true } else { false } }
}

extension FeedbackPR {
    /// The first rule that matches wins. Two choices differ from the skill's table:
    /// - A change request I've already answered (pushed since, no open threads) waits on the reviewer
    ///   to re-review; one newer than my last push counts as `reviews` and so as feedback.
    /// - Approved with no CI at all is ready to merge. `readyToMerge` needs green checks and stays
    ///   that way, since notifications use it.
    var move: MyMove {
        if hasConflict { return .yours(.conflict) }
        if checksFailing { return .yours(.checksFailing) }
        if threads + reviews + comments + botThreads > 0 { return .yours(.feedback) }
        if checks == "PENDING" || checks == "EXPECTED" { return .waiting(.ci) }
        if pr.isDraft { return .yours(.readyForReview) }
        if decision == "APPROVED", checks == nil || checks == "SUCCESS" { return .yours(.merge) }
        return .waiting(.reviewers)
    }
}

extension MyMove.Reason {
    /// Order within Your move: what blocks first, a parked draft last.
    var urgency: Int {
        switch self {
        case .conflict: 0
        case .checksFailing: 1
        case .feedback: 2
        case .merge: 3
        case .readyForReview: 4
        }
    }
}

/// My PRs' sections, in display order.
enum MyGroup: Int, CaseIterable, Comparable {
    case yours, waiting, oldDrafts

    var title: String {
        switch self {
        case .yours: "Your move"
        case .waiting: "Waiting on others"
        case .oldDrafts: "Old drafts"
        }
    }

    static func < (a: MyGroup, b: MyGroup) -> Bool { a.rawValue < b.rawValue }

    /// A draft nobody touched for this long is parked on purpose, whatever its move.
    static let oldDraftDays = 30

    /// My open PRs split into sections, empty ones left out. A PR dismissed until new feedback
    /// (`dismissed[url]` ≥ its `latestAt`) waits. Your move: most urgent, then waiting longest first;
    /// the others: most recently updated first. Pure, for tests.
    static func sections(_ prs: [FeedbackPR], dismissed: [String: String], now: Date = Date())
        -> [(group: MyGroup, prs: [FeedbackPR])] {
        let parser = ISO8601DateFormatter()
        let cutoff = now.addingTimeInterval(-Double(oldDraftDays) * 86_400)
        func group(_ f: FeedbackPR) -> MyGroup {
            if f.pr.isDraft, let updated = parser.date(from: f.pr.updatedAt), updated < cutoff { return .oldDrafts }
            if !f.latestAt.isEmpty, f.latestAt <= (dismissed[f.pr.url] ?? "") { return .waiting }
            return f.move.isYours ? .yours : .waiting
        }
        func urgency(_ f: FeedbackPR) -> Int { if case .yours(let r) = f.move { r.urgency } else { 0 } }
        func waitingSince(_ f: FeedbackPR) -> String { f.latestAt.isEmpty ? f.pr.updatedAt : f.latestAt }

        return Dictionary(grouping: prs, by: group)
            .map { g, prs in
                (group: g, prs: g == .yours
                    ? prs.sorted { (urgency($0), waitingSince($0)) < (urgency($1), waitingSince($1)) }
                    : prs.sorted { $0.pr.updatedAt > $1.pr.updatedAt })
            }
            .sorted { $0.group < $1.group }
    }
}

extension FeedbackPR {
    /// What a row with nothing new says about its move, when the status badge doesn't already:
    /// "2 bot threads", "ready for review?", "approved", "waiting on reviewers". Nil otherwise.
    var moveHint: String? {
        switch move {
        case .yours(.feedback) where isQuiet: "\(botThreads) bot thread\(botThreads == 1 ? "" : "s")"
        case .yours(.readyForReview): "ready for review?"
        case .yours(.merge) where !readyToMerge: "approved"
        case .waiting(.reviewers): "waiting on reviewers"
        default: nil
        }
    }
}
