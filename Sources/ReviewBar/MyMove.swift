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
