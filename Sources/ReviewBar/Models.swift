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
    /// CI state of the head commit, filled in with `headRefOid` for review requests.
    var checks: String? = nil
    /// Other reviewers' current verdicts, filled in with `headRefOid` for review requests.
    var verdicts: [ReviewingPR.Verdict]? = nil

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
    /// Your review is requested right now. With an earlier review of yours, that's a re-request.
    var isRequested = false
    /// Your latest review, skipping your pending draft and dismissed reviews. A later Comment
    /// (a thread reply is one) keeps your earlier verdict, as it does on GitHub.
    let myLastReview: MyReview?
    /// No review of yours counts, and one was dismissed: GitHub still lists you as a reviewer.
    var myReviewDismissed = false
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
    /// Like `latestAt`, but nil when nobody else has reviewed or commented (`latestAt` then
    /// falls back to the PR's `updatedAt`, which your own comments move).
    var lastOtherAt: String? = nil
    /// When the head commit was pushed, as near as GitHub tells: its first CI check suite is
    /// created on the push. Without CI, when the commit was made (GitHub no longer reports pushes).
    var headPushedAt: String? = nil
    /// Your latest comment in the PR's conversation (outside review threads).
    var myLastCommentAt: String? = nil
    /// The author's latest comment in the PR's conversation (outside review threads).
    var authorLastCommentAt: String? = nil
    var id: String { pr.url }

    /// Someone else reviewed or commented after the snapshot, or the head moved. Pure, for tests.
    func changed(since s: PRSnapshot) -> Bool {
        (lastOtherAt ?? "") > s.at || (pr.headRefOid != nil && pr.headRefOid != s.head)
    }

    /// Muted for good, or until something changes after `until`. A request you never reviewed
    /// can only be muted for good (such as a long-lived POC); a re-request always shows, since
    /// someone asked again. Pure, for tests.
    func isMuted(forever: Bool, until: PRSnapshot?) -> Bool {
        if isRequested { return forever && myLastReview == nil }
        return forever || until.map { !changed(since: $0) } ?? false
    }

    struct MyReview: Hashable {
        let state: String      // APPROVED, CHANGES_REQUESTED or COMMENTED
        let commit: String?    // nil when a force-push deleted it
        let at: String
    }

    struct Verdict: Codable, Hashable {
        let login: String
        let state: String      // APPROVED or CHANGES_REQUESTED
    }

    enum Turn: Equatable {
        case yours(Reason)
        case authors
        /// You approved, and nothing changed since or you commented on what did.
        case done
    }

    enum Reason: Equatable { case requested, reRequested, dismissed, newCommits, reply, authorReplied }

    /// Your last review was of an older commit. A review whose commit is gone counts too.
    /// Replying in a thread also creates a review on GitHub, so a reply after new commits
    /// makes them look seen; GitHub doesn't tell replies from reviews.
    var hasNewCommits: Bool {
        guard let mine = myLastReview, let head = pr.headRefOid else { return false }
        return mine.commit != head
    }

    /// Someone else reviewed or commented after your last review.
    var othersSpokeSinceReview: Bool {
        guard let mine = myLastReview, let other = lastOtherAt else { return false }
        return other > mine.at
    }

    /// You commented in the conversation after the head commit and after your last review
    /// ("CI is green, before I approve could you…"), so you have seen the new commits. In a repo
    /// without CI it goes by commit time, so a commit made before your comment but pushed after
    /// it reads as seen; the push notification still fires for it.
    var commentedOnHead: Bool {
        guard let c = myLastCommentAt, let head = headPushedAt else { return false }
        return c > head && c > (myLastReview?.at ?? "")
    }

    /// The author commented in the conversation after your last review or comment.
    var authorRepliedSinceYou: Bool {
        guard let a = authorLastCommentAt,
              let mine = [myLastReview?.at, myLastCommentAt].compactMap({ $0 }).max() else { return false }
        return a > mine
    }

    /// New commits or a reply in your threads since your review: something to verify.
    var verifyIsDue: Bool { hasNewCommits || waiting > 0 }

    var turn: Turn {
        if isRequested { return .yours(myLastReview == nil ? .requested : .reRequested) }
        if myReviewDismissed { return .yours(.dismissed) }
        if hasNewCommits && !commentedOnHead { return .yours(.newCommits) }
        if waiting > 0 { return .yours(.reply) }
        if authorRepliedSinceYou { return .yours(.authorReplied) }
        return myLastReview?.state == "APPROVED" ? .done : .authors
    }

    /// The Reviewing tab's sections, in display order.
    enum Group: Int, CaseIterable, Comparable {
        /// `muted` is never a PR's own group: `sections` puts muted PRs there.
        case yours, authors, done, muted
        static func < (a: Group, b: Group) -> Bool { a.rawValue < b.rawValue }

        var title: String {
            switch self {
            case .yours: "Your turn"
            case .authors: "Author's turn"
            case .done: "Done"
            case .muted: "Muted"
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

    /// Non-empty sections in display order; muted PRs last, in their own section. Your turn puts
    /// the longest-open PRs first, so old requests stay on top (the blue dot marks what's new);
    /// the other sections put the newest activity first. Pure, for tests.
    static func sections(_ prs: [ReviewingPR], muted: (ReviewingPR) -> Bool = { _ in false })
        -> [(group: Group, prs: [ReviewingPR])] {
        Dictionary(grouping: prs, by: { muted($0) ? .muted : $0.group })
            .sorted { $0.key < $1.key }
            .map { group, prs in
                (group, group == .yours
                    ? prs.sorted { ($0.pr.createdAt ?? "") < ($1.pr.createdAt ?? "") }
                    : prs.sorted { $0.latestAt > $1.latestAt })
            }
    }

    /// One line for the list: why it's your turn (or what you last said), replies, your threads,
    /// then other people's verdicts.
    var status: String {
        let reason: String? = switch turn {
        case .yours(.requested): "Review requested"
        case .yours(.reRequested): "Review re-requested"
        case .yours(.dismissed): "Your review was dismissed"
        case .yours(.newCommits): "New commits since your review"
        case .yours(.reply): nil   // the reply count below says it
        case .yours(.authorReplied): "\(pr.author.login) replied"
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

/// A PR you review at one moment: a time (ISO 8601) and its head commit. Stored per PR url for
/// "new since you last looked"; compared with `ReviewingPR.changed(since:)`.
struct PRSnapshot: Codable, Equatable {
    let at: String
    let head: String?

    /// The old Replies tab's dismissals that still hide a reply, as "mute until something
    /// happens" from now on: the later of the dismissal and the PR's last activity by others,
    /// since a thread reply is also a review whose time can be a little later. The head is the
    /// one you reviewed, so commits since then still show (a dismissal only hid replies). Pure, for tests.
    static func mutes(fromDismissed dismissed: [String: String], replies: [ReplyPR],
                      reviewing: [ReviewingPR]) -> [String: PRSnapshot] {
        var out: [String: PRSnapshot] = [:]
        for reply in replies {
            guard let at = dismissed[reply.pr.url], at >= reply.latestAt,
                  let r = reviewing.first(where: { $0.pr.url == reply.pr.url }) else { continue }
            out[reply.pr.url] = PRSnapshot(at: max(at, r.lastOtherAt ?? ""),
                                           head: r.myLastReview?.commit ?? r.pr.headRefOid)
        }
        return out
    }

    /// Drops snapshots of PRs not listed since `cutoff`. `lastListed` says when each PR was
    /// last in the list; without an entry, the snapshot's own time stands in. Pure, for tests.
    static func pruned(_ all: [String: PRSnapshot], listed: Set<String>, lastListed: [String: String],
                       cutoff: String) -> [String: PRSnapshot] {
        all.filter { listed.contains($0.key) || (lastListed[$0.key] ?? $0.value.at) > cutoff }
    }
}

/// What happened on a PR you review since your last review, loaded when you open it.
struct ReviewingDetail: Equatable {
    var commits: Commits = .unknown
    /// Threads you opened: ones with a reply first, then open, then resolved.
    let myThreads: [MyThread]
    /// Unresolved threads other people opened, by login. Never you, the author or a bot.
    let openThreadsBy: [String: Int]
    /// What other people did after your last review, newest first. Never you or a bot.
    /// Resolving a thread has no date on GitHub, so it isn't here; Your threads shows it.
    var activity: [Activity] = []
    /// More happened than one query reads: older activity is only on GitHub.
    var activityCapped = false

    struct Activity: Equatable {
        let login: String
        let kind: Kind
        let at: String   // ISO 8601
        let url: String?

        enum Kind: Equatable {
            case approved
            case changesRequested(comments: Int)
            /// A review that is neither approval nor change request: a summary, new comments, or both.
            case reviewed(comments: Int)
            /// Answers in existing threads only. GitHub stores each as a review, but not in the timeline.
            case replied(threads: Int)
            /// On the PR's conversation, not in a thread.
            case commented
            case forcePushed(times: Int)
            /// Nil: from you.
            case reviewRequested(from: String?)
            case dismissedReview(of: String?)
            case readyForReview, convertedToDraft
        }

        var text: String {
            func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
            let what = switch kind {
            case .approved: "approved"
            case .changesRequested(let n): "requested changes" + (n > 0 ? " · " + plural(n, "comment") : "")
            case .reviewed(let n): n > 0 ? "reviewed · " + plural(n, "comment") : "commented in a review"
            case .replied(let n): "replied in " + plural(n, "thread")
            case .commented: "commented on the PR"
            case .forcePushed(let n): n == 1 ? "force-pushed" : "force-pushed \(n) times"
            case .reviewRequested(let who): who.map { "requested a review from \($0)" } ?? "requested your review"
            case .dismissedReview(let who): who.map { "dismissed \($0)'s review" } ?? "dismissed your review"
            case .readyForReview: "marked it ready for review"
            case .convertedToDraft: "converted it to a draft"
            }
            return "\(login) \(what)"
        }
    }

    struct MyThread: Equatable {
        let path: String
        let line: Int?
        /// The comment's first line.
        let snippet: String
        /// The whole comment without code blocks, for the tooltip.
        let fullText: String
        let url: String?
        let state: State
        /// The code it points at has changed since.
        let isOutdated: Bool

        enum State: Equatable {
            /// Unresolved, and someone else (not a bot) spoke last.
            case replied(by: String)
            case open, resolved
        }

        /// Icons from the pr-review skill's Severity section, most severe first.
        /// ReviewDoc.Severity is the app's own review format, not this one.
        enum Severity: Int, CaseIterable, Comparable {
            case severe, high, medium, low, question

            var icon: String {
                switch self {
                case .severe: "🚨"
                case .high: "🔴"
                case .medium: "🟠"
                case .low: "🟡"
                case .question: "❓"
                }
            }

            /// The skill's rule: only these block a merge.
            var isBlocking: Bool { self == .severe || self == .high }

            /// From a title's leading icon. Compares the first Unicode scalar, so "❓" matches
            /// with or without its U+FE0F variation selector.
            init?(title: String) {
                guard let first = title.unicodeScalars.first,
                      let s = Self.allCases.first(where: { $0.icon.unicodeScalars.first == first }) else { return nil }
                self = s
            }

            static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
        }

        /// Nil for comments that don't start with one of the skill's icons.
        var severity: Severity? { Severity(title: snippet) }

        /// The snippet without its leading severity icon, which the app draws as a symbol instead.
        var title: String {
            guard severity != nil else { return snippet }
            var rest = snippet.unicodeScalars.dropFirst()
            if rest.first == "\u{FE0F}" { rest = rest.dropFirst() }
            return String(String.UnicodeScalarView(rest)).trimmingCharacters(in: .whitespaces)
        }

        var location: String { line.map { "\(path):\($0)" } ?? path }

        var stateText: String {
            let s = switch state {
            case .replied(let who): "\(who) replied"
            case .open: "open"
            case .resolved: "resolved"
            }
            return isOutdated ? s + " · code changed" : s
        }
    }

    /// How the branch moved between the commit you last reviewed and the head.
    enum Commits: Equatable {
        case same
        case new(count: Int, commits: [Backend.CompareInfo.Commit])
        case rebased
        /// Your review has no commit: a force-push deleted it.
        case gone
        /// You haven't reviewed it, or the compare failed.
        case unknown

        init(review: ReviewingPR.MyReview?, head: String?, compare: Backend.CompareInfo?) {
            guard let review else { self = .unknown; return }
            guard let reviewed = review.commit else { self = .gone; return }
            if reviewed == head { self = .same; return }
            guard let compare else { self = .unknown; return }
            self = compare.isIncremental ? .new(count: compare.aheadBy, commits: compare.commits) : .rebased
        }

        var summary: String {
            switch self {
            case .same: "No new commits since your review"
            case .new(let n, _): "\(n) new commit\(n == 1 ? "" : "s") since your review"
            case .rebased: "The branch was rebased since your review, so the new commits can't be told apart"
            case .gone: "The commit you reviewed is gone (force-push)"
            case .unknown: "Couldn't compare with the commit you reviewed"
            }
        }
    }

    struct Reviewer: Equatable {
        let login: String
        let text: String
    }

    /// People with a verdict (from the list) or unresolved threads (from here), by login.
    func reviewers(_ verdicts: [ReviewingPR.Verdict]) -> [Reviewer] {
        let byLogin = Dictionary(verdicts.map { ($0.login, $0.state) }, uniquingKeysWith: { $1 })
        return Set(byLogin.keys).union(openThreadsBy.keys).sorted().map { login in
            let verdict = byLogin[login].map { $0 == "APPROVED" ? "approved" : "requested changes" }
            let open = openThreadsBy[login].map { "\($0) open thread\($0 == 1 ? "" : "s")" }
            return Reviewer(login: login, text: [verdict, open].compactMap { $0 }.joined(separator: " · "))
        }
    }

    private var myOpenSeverities: [MyThread.Severity] {
        myThreads.filter { $0.state != .resolved }.compactMap(\.severity)
    }

    /// Your unresolved threads per severity, most severe first ("open: 1 🔴, 1 ❓").
    /// Empty when none has an icon.
    var openBySeverity: [(severity: MyThread.Severity, count: Int)] {
        Dictionary(grouping: myOpenSeverities, by: { $0 }).sorted { $0.key < $1.key }
            .map { (severity: $0.key, count: $0.value.count) }
    }

    /// Your unresolved 🚨/🔴 threads.
    var blockingOpen: Int { myOpenSeverities.filter(\.isBlocking).count }
}

/// One of your own open PRs, with any reviewer feedback you have not answered yet.
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
    /// ISO 8601; empty when the PR is quiet.
    let latestAt: String
    let latestBy: String
    /// Combined CI state of the head commit: SUCCESS, FAILURE, ERROR, PENDING, EXPECTED or nil.
    var checks: String? = nil
    /// MERGEABLE, CONFLICTING or UNKNOWN (GitHub still computing).
    var mergeable: String? = nil
    /// GitHub's `mergeStateStatus`: CLEAN when nothing blocks the merge, BLOCKED, BEHIND and so on.
    var mergeState: String? = nil
    /// A reviewer (not a bot) left a review, comment or thread, answered or not.
    var hasFeedback = false
    /// The PR's head branch name.
    var branch: String? = nil
    /// When the head commit was made (ISO 8601). Unlike `updatedAt`, labels and bulk edits don't move it.
    var lastCommitAt: String? = nil
    /// How many of `reviews` are approvals: news, but nothing to answer.
    var approvals = 0
    /// Unresolved review threads whose last comment is a bot's (CodeRabbit). Only `move` reads it:
    /// bots never notify or count.
    var botThreads = 0
    /// Someone is asked to review. Defaults to true; only `move` reads it, to spot a PR nobody was asked about.
    var reviewersRequested = true
    var id: String { pr.url }

    func with(latestAt: String, latestBy: String) -> FeedbackPR {
        FeedbackPR(pr: pr, decision: decision, threads: threads, reviews: reviews, comments: comments,
                   latestAt: latestAt, latestBy: latestBy, checks: checks, mergeable: mergeable,
                   mergeState: mergeState, hasFeedback: hasFeedback, branch: branch, lastCommitAt: lastCommitAt,
                   approvals: approvals, botThreads: botThreads, reviewersRequested: reviewersRequested)
    }

    /// Nothing new: no unanswered feedback, no blocker, not ready to merge. Listed in My PRs,
    /// but never notifies or counts, and can't be dismissed.
    var isQuiet: Bool { latestAt.isEmpty }

    var checksFailing: Bool { checks == "FAILURE" || checks == "ERROR" }
    var hasConflict: Bool { mergeable == "CONFLICTING" }
    /// No checks at all (`nil`: a repo without CI) counts as green only when GitHub says nothing
    /// blocks the merge: a required check whose workflow skipped this PR also leaves no checks.
    /// Right after a push, in a repo with CI but no required checks, GitHub reports CLEAN with no
    /// checks for about 2 seconds before they register. A refresh landing there shows the row ready
    /// until the next one; the notification is keyed by the approval, so it doesn't fire twice.
    var readyToMerge: Bool {
        decision == "APPROVED" && mergeable == "MERGEABLE"
            && (checks == "SUCCESS" || (checks == nil && mergeState == "CLEAN"))
    }

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
