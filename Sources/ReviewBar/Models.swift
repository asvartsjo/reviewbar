import Foundation

struct PR: Identifiable, Codable, Hashable {
    let number: Int
    let title: String
    let url: String
    let isDraft: Bool
    let updatedAt: String
    let repository: Repo
    let author: Author
    /// Head commit, filled in by `Backend.fetchPRs` (search results don't include it).
    var headRefOid: String?
    /// When the PR was opened; used to put the longest-waiting review requests first.
    var createdAt: String? = nil

    struct Repo: Codable, Hashable { let nameWithOwner: String }
    struct Author: Codable, Hashable { let login: String }

    var id: String { url }
    /// Changes when the PR gets new commits (not on comments), so stale reviews are not reused.
    /// Falls back to `updatedAt` if the head commit could not be fetched.
    var reviewKey: String { url + "@" + (headRefOid ?? updatedAt) }

    /// Short label for the reviewed version, used in file names and prompts.
    var versionLabel: String {
        headRefOid.map { String($0.prefix(7)) }
            ?? updatedAt.filter { $0.isNumber }
    }
}

struct SavedReview: Codable, Identifiable {
    let pr: PR
    let text: String
    let date: Date
    /// What produced it, e.g. "sonnet · high". Nil for reviews saved before this was recorded.
    var producedBy: String?
    /// Set when this reviews only the commits after an earlier review: that review's short commit.
    var sinceCommit: String?
    /// True when a since-review had to fall back to the full diff (branch rebased or force-pushed).
    var sinceFellBack: Bool?
    var id: String { pr.reviewKey }
}

/// A PR you reviewed where someone answered in one of your unresolved review threads.
struct ReplyPR: Identifiable, Hashable {
    let pr: PR
    /// Unresolved threads you took part in whose last comment is someone else's.
    let waiting: Int
    let latestAt: String   // ISO 8601, newest reply among those threads
    let latestBy: String
    var id: String { pr.url }
}

/// A PR you review: requested from you now, or reviewed by you before.
struct ReviewingPR: Identifiable, Hashable {
    let pr: PR
    /// In Awaiting me right now. With an earlier review of yours, that's a re-request.
    var isRequested = false
    /// Your latest review, skipping your pending draft and dismissed reviews.
    let myLastReview: MyReview?
    /// Unresolved threads you took part in whose last comment is someone else's (not a bot).
    let waiting: Int
    /// Threads you opened, and how many of those are resolved or point at changed code.
    let myThreads: Int
    let resolved: Int
    let outdated: Int
    /// Other people's current verdicts, by login. Never you, the author or a bot.
    let verdicts: [Verdict]
    /// Combined CI state of the head commit: SUCCESS, FAILURE, ERROR, PENDING, EXPECTED or nil.
    let checks: String?
    let latestAt: String   // ISO 8601, newest review or comment by someone else
    var id: String { pr.url }

    struct MyReview: Hashable {
        let state: String      // APPROVED, CHANGES_REQUESTED or COMMENTED
        let commit: String?    // nil when a force-push deleted it
        let at: String
    }

    struct Verdict: Hashable {
        let login: String
        let state: String      // APPROVED or CHANGES_REQUESTED
    }

    enum Turn: Equatable {
        case yours(Reason)
        case authors
        /// You approved and nothing changed since.
        case done
    }

    enum Reason: Equatable { case requested, reRequested, newCommits, reply }

    /// Your last review was of an older commit. A review whose commit is gone counts too.
    /// Replying in a thread also creates a review on GitHub, so a reply after new commits
    /// makes them look seen; GitHub doesn't tell replies from reviews.
    var hasNewCommits: Bool {
        guard let mine = myLastReview, let head = pr.headRefOid else { return false }
        return mine.commit != head
    }

    var turn: Turn {
        if isRequested { return .yours(myLastReview == nil ? .requested : .reRequested) }
        if hasNewCommits { return .yours(.newCommits) }
        if waiting > 0 { return .yours(.reply) }
        return myLastReview?.state == "APPROVED" ? .done : .authors
    }

    /// The Reviewing tab's sections, in display order.
    enum Group: Int, CaseIterable, Comparable {
        case yours, authors, done
        static func < (a: Group, b: Group) -> Bool { a.rawValue < b.rawValue }

        var title: String {
            switch self {
            case .yours: "Your turn"
            case .authors: "Author's turn"
            case .done: "Done"
            }
        }
    }

    var group: Group {
        switch turn {
        case .yours: .yours
        case .authors: .authors
        case .done: .done
        }
    }

    /// Non-empty sections in display order, newest activity first inside each. Pure, for tests.
    static func sections(_ prs: [ReviewingPR]) -> [(group: Group, prs: [ReviewingPR])] {
        Dictionary(grouping: prs, by: \.group)
            .sorted { $0.key < $1.key }
            .map { ($0.key, $0.value.sorted { $0.latestAt > $1.latestAt }) }
    }

    /// One line for the list: why it's your turn (or what you last said), replies, your threads,
    /// then other people's verdicts.
    var status: String {
        let reason: String? = switch turn {
        case .yours(.requested): "Review requested"
        case .yours(.reRequested): "Review re-requested"
        case .yours(.newCommits): "New commits since your review"
        case .yours(.reply): nil   // the reply count below says it
        case .authors, .done:
            switch myLastReview?.state {
            case "APPROVED": "You approved"
            case "CHANGES_REQUESTED": "You requested changes"
            default: "You commented"
            }
        }
        let replies = waiting == 0 ? nil : "\(waiting) \(waiting == 1 ? "reply" : "replies") waiting"
        let threads = myThreads == 0 ? nil : "\(resolved)/\(myThreads) of your threads resolved"
        let others = verdicts.map { "\($0.login) \($0.state == "APPROVED" ? "approved" : "requested changes")" }
        return ([reason, replies, threads].compactMap { $0 } + others).joined(separator: " · ")
    }
}

/// One of your own open PRs with reviewer feedback you have not answered yet.
struct FeedbackPR: Identifiable, Hashable {
    let pr: PR
    /// GitHub's overall review decision: APPROVED, CHANGES_REQUESTED, REVIEW_REQUIRED or nil.
    let decision: String?
    /// Unresolved review threads whose last comment is a reviewer's.
    let threads: Int
    /// Approvals, change requests and review summaries since your last push or comment.
    let reviews: Int
    /// Conversation comments since your last push or comment.
    let comments: Int
    let latestAt: String   // ISO 8601
    let latestBy: String
    /// Combined CI state of the head commit: SUCCESS, FAILURE, ERROR, PENDING, EXPECTED or nil.
    var checks: String? = nil
    /// MERGEABLE, CONFLICTING or UNKNOWN (GitHub still computing).
    var mergeable: String? = nil
    var id: String { pr.url }

    func with(latestAt: String, latestBy: String) -> FeedbackPR {
        FeedbackPR(pr: pr, decision: decision, threads: threads, reviews: reviews, comments: comments,
                   latestAt: latestAt, latestBy: latestBy, checks: checks, mergeable: mergeable)
    }

    var checksFailing: Bool { checks == "FAILURE" || checks == "ERROR" }
    var hasConflict: Bool { mergeable == "CONFLICTING" }
    var readyToMerge: Bool { decision == "APPROVED" && checks == "SUCCESS" && mergeable == "MERGEABLE" }

    /// What blocks or unblocks the PR, most urgent first; nil when there's nothing to say.
    var status: String? {
        if hasConflict { return "Merge conflict" }
        if checksFailing { return "Checks failing" }
        if readyToMerge { return "Ready to merge" }
        if checks == "PENDING" || checks == "EXPECTED" { return "Checks running" }
        return nil
    }

    var summary: String {
        func n(_ count: Int, _ word: String) -> String? {
            count == 0 ? nil : "\(count) \(word)\(count == 1 ? "" : "s")"
        }
        let counts = [n(threads, "thread"), n(reviews, "review"), n(comments, "comment")].compactMap { $0 }
        return counts.isEmpty ? (status ?? "") : counts.joined(separator: " · ")
    }
}

enum ReviewState {
    case idle, running
    case done(String)
    case failed(String)
}
