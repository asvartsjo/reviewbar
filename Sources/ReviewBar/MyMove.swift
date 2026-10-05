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
        /// CI still running on a ready PR: mine to watch, though there's nothing to click yet.
        case checksRunning
        /// Ready for review, but nobody was asked to review it.
        case needsReviewer
    }

    enum On: Equatable { case reviewers }

    var isYours: Bool { if case .yours = self { true } else { false } }
}

extension FeedbackPR {
    /// The first rule that matches wins. Two choices differ from the skill's table:
    /// - A change request I've already answered (pushed since, no open threads) waits on the reviewer
    ///   to re-review; one newer than my last push counts as `reviews` and so as feedback.
    /// - No reviewer requested and nobody has reviewed: my move (ask someone), not waiting on others.
    /// - A draft is mine even while CI runs: nobody can review it yet, so it never waits on others.
    /// - Checks running is mine too, not waiting on CI: I watch a fresh push until it goes green or red.
    /// - Approved with no CI at all is ready to merge. `readyToMerge` needs green checks and stays
    ///   that way, since notifications use it.
    var move: MyMove {
        if hasConflict { return .yours(.conflict) }
        if checksFailing { return .yours(.checksFailing) }
        if threads + (reviews - approvals) + comments + botThreads > 0 { return .yours(.feedback) }
        if pr.isDraft { return .yours(.readyForReview) }
        if !reviewersRequested, !hasFeedback, decision != "APPROVED" { return .yours(.needsReviewer) }
        if checks == "PENDING" || checks == "EXPECTED" { return .yours(.checksRunning) }
        if decision == "APPROVED", checks == nil || checks == "SUCCESS" { return .yours(.merge) }
        return .waiting(.reviewers)
    }
}

/// My PRs' sections, in display order.
enum MyGroup: Int, CaseIterable, Comparable {
    case yours, waiting, parked

    var title: String {
        switch self {
        case .yours: "Your move"
        case .waiting: "Waiting on others"
        case .parked: "Parked"
        }
    }

    static func < (a: MyGroup, b: MyGroup) -> Bool { a.rawValue < b.rawValue }

    /// A draft with no commit for this long is parked on purpose, whatever its move.
    static let oldDraftDays = 30

    /// My open PRs split into sections, empty ones left out. Parked: the ones I parked, and drafts
    /// with no commit for `oldDraftDays`. A PR dismissed until new feedback (`dismissed[url]` ≥ its
    /// `latestAt`) waits. Every section lists the most recently created PR first. Pure, for tests.
    static func sections(_ prs: [FeedbackPR], dismissed: [String: String], parked: Set<String> = [],
                         now: Date = Date()) -> [(group: MyGroup, prs: [FeedbackPR])] {
        let parser = ISO8601DateFormatter()
        let cutoff = now.addingTimeInterval(-Double(oldDraftDays) * 86_400)
        func group(_ f: FeedbackPR) -> MyGroup {
            if parked.contains(f.pr.url) { return .parked }
            if f.pr.isDraft, let last = parser.date(from: f.lastCommitAt ?? f.pr.updatedAt), last < cutoff { return .parked }
            if !f.latestAt.isEmpty, f.latestAt <= (dismissed[f.pr.url] ?? "") { return .waiting }
            return f.move.isYours ? .yours : .waiting
        }
        return Dictionary(grouping: prs, by: group)
            .map { g, prs in (group: g, prs: prs.sorted { ($0.pr.createdAt ?? "") > ($1.pr.createdAt ?? "") }) }
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
