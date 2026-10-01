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
