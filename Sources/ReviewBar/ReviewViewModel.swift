import Foundation
import AppKit

@MainActor
final class ReviewViewModel: ObservableObject {
    /// One instance for the app, so URLs from review pages (reviewbar://…) reach it.
    static let shared = ReviewViewModel()

    @Published var prs: [PR] = []
    @Published var saved: [SavedReview] = []
    @Published var loading = false
    @Published var error: String?
    @Published var reviews: [String: ReviewState] = [:]   // keyed by PR.reviewKey
    @Published var replies: [ReplyPR] = []
    /// PRs you review: reviewed before, or requested now (merged in from `prs`).
    @Published var reviewing: [ReviewingPR] = []
    @Published var myPRs: [FeedbackPR] = []
    /// Shown under the terminal button, e.g. after copying a command.
    @Published var terminalNotice: String?
    /// Quick-model summaries, keyed by `summaryKey` so newer comments make them stale. Not saved.
    @Published var summaries: [String: ReviewState] = [:]
    /// PR url -> `latestAt` of the reply you dismissed. Newer replies bring the PR back.
    @Published private var dismissed: [String: String] =
        UserDefaults.standard.dictionary(forKey: "dismissedReplies") as? [String: String] ?? [:]
    private var timer: Timer?
    private var lastRefresh: Date?
    private var refreshAgain = false
    /// What the previous successful refresh saw, per list; nil until the first one (the baseline).
    private var seenRequests: Set<String>?
    private var seenReplies: [String: String]?
    private var seenFeedback: [String: String]?
    /// Repos left out of searches because `gh` can't read them; cleared when Settings change.
    @Published private(set) var skippedRepos: Set<String> = []

    static let refreshInterval: TimeInterval = 300
    /// Opening the popover refreshes if the data is older than this.
    static let staleAfter: TimeInterval = 60

    init() {
        RepoList.migrateLegacySettings()
        saved = Store.load().sorted { $0.date > $1.date }
        for s in saved { reviews[s.id] = .done(s.text) }
        Notifier.requestAuthorization()

        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        Task { await watchNotifications() }
    }

    /// Near real-time updates: checks GitHub notifications about once a minute (as often as
    /// GitHub's X-Poll-Interval allows) and refreshes only when something new arrived. Unchanged
    /// checks answer 304 and don't count against the rate limit. The 5-minute timer stays as a
    /// fallback for changes that don't notify, like new commits on a PR you reviewed.
    private func watchNotifications() async {
        var etag: String?
        var interval: TimeInterval = 60
        while !Task.isCancelled {
            if let poll = await Backend.pollNotifications(etag: etag) {
                if poll.changed, etag != nil { await refresh() }
                etag = poll.etag ?? etag
                interval = max(poll.interval ?? 60, 30)
            }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }

    /// After Settings change: try every repo again, then refresh.
    func settingsChanged() async {
        skippedRepos = []
        // New repos or showing drafts again would look like a flood of new items: re-baseline.
        seenRequests = nil
        seenReplies = nil
        seenFeedback = nil
        seenMentions = nil
        await refresh()
    }

    /// For opening the popover: refresh unless it happened within the last minute.
    func refreshIfStale() async {
        if let last = lastRefresh, Date().timeIntervalSince(last) < Self.staleAfter { return }
        await refresh()
    }

    func refresh() async {
        // One at a time; a request made meanwhile (e.g. after editing Settings) runs right after.
        if loading { refreshAgain = true; return }
        loading = true
        let skip = skippedRepos
        async let fetchedPRs = Backend.fetchPRs(skipping: skip)
        async let fetchedReplies = Backend.fetchReplies(skipping: skip)
        async let fetchedReviewing = Backend.fetchReviewing(skipping: skip)
        async let fetchedMine = Backend.fetchMyPRs(skipping: skip)
        let week = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-7 * 86_400))
        async let fetchedMentions = Backend.fetchMentions(since: week, repos: RepoList.load())
        var errors: [String] = []
        var alerts: [ReviewAlert] = []

        // Each list only updates (and only notifies) when its own fetch succeeded.
        do {
            prs = PRFilter.others(try await fetchedPRs, includeDrafts: PRFilter.includeDrafts)
            let fresh = AlertDiff.newRequests(prs, seen: seenRequests)
            alerts += fresh.map(ReviewAlert.request)
            if AutoReview.isOn { autoReview(fresh) }
            seenRequests = Set(prs.map(\.url))
        } catch { errors.append(error.localizedDescription) }
        do {
            replies = PRFilter.others(try await fetchedReplies, includeDrafts: PRFilter.includeDrafts)
            alerts += AlertDiff.newer(visibleReplies, seen: seenReplies, url: \.pr.url, latestAt: \.latestAt)
                .map(ReviewAlert.reply)
            seenReplies = AlertDiff.latestByURL(replies, url: \.pr.url, latestAt: \.latestAt)
        } catch { errors.append("Replies: \(error.localizedDescription)") }
        do {
            let reviewed = PRFilter.others(try await fetchedReviewing, includeDrafts: PRFilter.includeDrafts)
            reviewing = Backend.merge(reviewed, requested: prs)
        } catch { errors.append("Reviewing: \(error.localizedDescription)") }
        do {
            myPRs = try await fetchedMine
            alerts += AlertDiff.newer(visibleFeedback, seen: seenFeedback, url: \.pr.url, latestAt: \.latestAt)
                .map(ReviewAlert.feedback)
            seenFeedback = AlertDiff.latestByURL(myPRs, url: \.pr.url, latestAt: \.latestAt)
        } catch { errors.append("My PRs: \(error.localizedDescription)") }

        // Mentions are best effort: an empty list on failure, and only new ones notify.
        mentions = await fetchedMentions
        let newMentions = AlertDiff.newer(visibleMentions, seen: seenMentions, url: \.url, latestAt: \.updatedAt)
        seenMentions = AlertDiff.latestByURL(mentions, url: \.url, latestAt: \.updatedAt)
        newMentions.forEach(Notifier.mention)

        // A failed search is usually one repo gh can't read: find it, leave it out, try again.
        if !errors.isEmpty {
            let failing = Set(await Backend.inaccessibleRepos())
            let bad = failing.subtracting(skippedRepos)
            // If every repo fails, it's gh, the network or GitHub, not a repo: skip nothing.
            if !bad.isEmpty, failing.count < RepoList.load().count {
                skippedRepos.formUnion(bad)
                refreshAgain = true
            }
        }
        if !skippedRepos.isEmpty {
            errors.insert("Skipping \(skippedRepos.sorted().joined(separator: ", ")): gh can't read "
                + "\(skippedRepos.count == 1 ? "it" : "them"). Check the name in Settings, or run "
                + "`gh auth refresh` if the org uses SSO.", at: 0)
        }
        self.error = errors.isEmpty ? nil : errors.joined(separator: "\n")
        Notifier.post(alerts)
        lastRefresh = Date()
        loading = false
        if refreshAgain {
            refreshAgain = false
            await refresh()
        }
    }

    /// Replies you have not dismissed (or that are newer than what you dismissed).
    var visibleReplies: [ReplyPR] {
        replies.filter { $0.latestAt > (dismissed[$0.pr.url] ?? "") }
    }

    func reply(for pr: PR) -> ReplyPR? { visibleReplies.first { $0.pr.url == pr.url } }

    func dismissReplies(_ r: ReplyPR) { dismiss(r.pr.url, until: r.latestAt) }

    var reviewingSections: [(group: ReviewingPR.Group, prs: [ReviewingPR])] { ReviewingPR.sections(reviewing) }

    var yourTurnCount: Int { reviewing.filter { $0.group == .yours }.count }

    func reviewingPR(for pr: PR) -> ReviewingPR? { reviewing.first { $0.pr.url == pr.url } }

    struct DetailLoad {
        var detail: ReviewingDetail?
        var loading = false
        var error: String?
    }

    /// By PR url. Reloaded each time a PR is opened; the previous result shows meanwhile.
    @Published private(set) var details: [String: DetailLoad] = [:]

    func detailLoad(for pr: PR) -> DetailLoad { details[pr.url] ?? DetailLoad() }

    func loadDetail(_ r: ReviewingPR) {
        let url = r.pr.url
        guard details[url]?.loading != true else { return }
        details[url, default: DetailLoad()].loading = true
        details[url]?.error = nil
        Task {
            do {
                details[url]?.detail = try await Backend.fetchReviewingDetail(r)
            } catch {
                details[url]?.error = error.localizedDescription
            }
            details[url]?.loading = false
        }
    }

    @Published var mentions: [Mention] = []
    private var seenMentions: [String: String]?

    /// Mentions from the last week you have not dismissed.
    var visibleMentions: [Mention] {
        mentions.filter { $0.updatedAt > (dismissed["mention:" + $0.url] ?? "") }
    }

    func dismissMention(_ m: Mention) { dismiss("mention:" + m.url, until: m.updatedAt) }

    /// Your PRs with feedback you have not dismissed (or newer than what you dismissed).
    var visibleFeedback: [FeedbackPR] {
        myPRs.filter { $0.latestAt > (dismissed[$0.pr.url] ?? "") }
    }

    func feedback(for pr: PR) -> FeedbackPR? { visibleFeedback.first { $0.pr.url == pr.url } }

    /// True for your own PRs (with feedback, dismissed or not).
    func isMine(_ pr: PR) -> Bool { myPRs.contains { $0.pr.url == pr.url } }

    func dismissFeedback(_ f: FeedbackPR) { dismiss(f.pr.url, until: f.latestAt) }

    private func dismiss(_ url: String, until latestAt: String) {
        dismissed[url] = latestAt
        UserDefaults.standard.set(dismissed, forKey: "dismissedReplies")
    }

    /// Distinct PRs needing you: review requests, replies, new commits since your review and
    /// feedback on your PRs. Only the new-commits part of Reviewing counts: its requests and
    /// replies are already here, and replies must honour Replies dismissals.
    var badgeCount: Int {
        Set(prs.map(\.url))
            .union(visibleReplies.map(\.pr.url))
            .union(reviewing.filter { $0.turn == .yours(.newCommits) }.map(\.pr.url))
            .union(visibleFeedback.map(\.pr.url))
            .union(visibleMentions.map(\.url))
            .count
    }

    func state(for pr: PR) -> ReviewState { reviews[pr.reviewKey] ?? .idle }

    /// True if an older review of this PR exists (the PR has new activity since).
    func hasOlderReview(_ pr: PR) -> Bool {
        saved.contains { $0.pr.url == pr.url && $0.id != pr.reviewKey }
    }

    /// The newest earlier review of this PR that recorded its commit, when the PR has moved on
    /// to a different commit since: what "Review changes since…" builds on.
    func earlierReview(for pr: PR) -> SavedReview? {
        guard let head = pr.headRefOid else { return nil }
        return saved.first {
            $0.pr.url == pr.url && $0.id != pr.reviewKey
                && $0.pr.headRefOid != nil && $0.pr.headRefOid != head
        }
    }

    /// Full review of the current diff.
    func review(_ pr: PR) { run(pr, since: nil) }

    /// Review only the commits since `earlier` (falls back to the full diff after a rebase).
    func reviewChanges(_ pr: PR, since earlier: SavedReview) { run(pr, since: earlier) }

    /// Re-runs the same kind of review that is saved for this version.
    func rerun(_ pr: PR) {
        if savedReview(for: pr)?.sinceCommit != nil, let earlier = earlierReview(for: pr) {
            reviewChanges(pr, since: earlier)
        } else {
            review(pr)
        }
    }

    /// Running reviews by review key, so they can be cancelled.
    private var running: [String: Task<Void, Never>] = [:]

    /// Stops a running review and puts back what was there before (a saved review, or nothing).
    func cancelReview(_ pr: PR) {
        running[pr.reviewKey]?.cancel()
    }

    // MARK: Review all

    /// PRs "Review all" would pick up: no review of this version yet, and none running.
    var unreviewed: [PR] {
        prs.filter { pr in
            switch state(for: pr) { case .idle, .failed: return true; default: return false }
        }
    }

    @Published private(set) var batch: (done: Int, total: Int)?
    private var batchTask: Task<Void, Never>?

    /// Reviews every unreviewed PR, reusing earlier notes where a PR moved on since. `parallel`
    /// runs up to three at once; otherwise one by one.
    func reviewAll(parallel: Bool) {
        let targets = unreviewed
        guard !targets.isEmpty, batchTask == nil else { return }
        batch = (0, targets.count)
        batchTask = Task {
            defer { batchTask = nil; batch = nil }
            let width = parallel ? 3 : 1
            for start in stride(from: 0, to: targets.count, by: width) {
                if Task.isCancelled { break }
                let group = targets[start..<min(start + width, targets.count)].map { pr in
                    run(pr, since: earlierReview(for: pr))
                }
                for t in group { await t.value; batch?.done += 1 }
            }
        }
    }

    /// Stops the batch and any review it started.
    func cancelAll() {
        batchTask?.cancel()
        for t in running.values { t.cancel() }
    }

    // MARK: Automatic reviews

    private var autoQueue: [PR] = []
    private var autoWorker: Task<Void, Never>?

    /// Queues new review requests and reviews them one at a time, so a burst of requests doesn't
    /// start many agents at once. Only PRs that appeared since the last refresh: turning this on
    /// (or launching the app) never reviews the whole backlog.
    func autoReview(_ fresh: [PR]) {
        autoQueue += fresh.filter { pr in
            !autoQueue.contains { $0.url == pr.url } && { if case .idle = state(for: pr) { true } else { false } }()
        }
        guard autoWorker == nil, !autoQueue.isEmpty else { return }
        autoWorker = Task {
            defer { autoWorker = nil }
            while !autoQueue.isEmpty, !Task.isCancelled {
                let pr = autoQueue.removeFirst()
                guard case .idle = state(for: pr) else { continue }
                await run(pr, since: earlierReview(for: pr)).value
                if case .done(let text) = state(for: pr) { Notifier.reviewReady(pr, text: text) }
            }
        }
    }

    // MARK: Draft review on GitHub

    @Published var draftState: [String: ReviewState] = [:]   // keyed by PR.reviewKey

    /// Posts the saved review's non-nit comments as a pending review, then opens the PR's files page.
    func createDraft(_ pr: PR) {
        guard case .done(let text) = state(for: pr) else { return }
        draftState[pr.reviewKey] = .running
        Task {
            do {
                let r = try await Backend.createDraftReview(pr, text: text)
                draftState[pr.reviewKey] = .done(r.loose == 0
                    ? "Draft review with \(r.inline) comment\(r.inline == 1 ? "" : "s") created. Submit it on GitHub."
                    : "Draft review created: \(r.inline) on lines, \(r.loose) in the summary (outside the diff). Submit it on GitHub.")
                if let u = URL(string: pr.url + "/files") { NSWorkspace.shared.open(u) }
            } catch {
                draftState[pr.reviewKey] = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Review page links

    /// Handles reviewbar://update?pr=<PR url> from the browser page: fetch the PR again, then
    /// review the new commits (or re-run if nothing moved) and reopen the page when done.
    /// reviewbar://rerun?pr=<url> always runs a full review of the current diff.
    func handle(_ url: URL) {
        guard url.scheme == "reviewbar",
              let prURL = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "pr" })?.value else { return }
        let full = url.host == "rerun"
        Task {
            await refresh()
            guard let pr = prs.first(where: { $0.url == prURL })
                    ?? saved.first(where: { $0.pr.url == prURL })?.pr else { return }
            if case .running = state(for: pr) { return }
            let task: Task<Void, Never>
            if full {
                task = run(pr, since: nil)
            } else if savedReview(for: pr) != nil {
                task = run(pr, since: savedReview(for: pr)?.sinceCommit != nil ? earlierReview(for: pr) : nil)
            } else {
                task = run(pr, since: earlierReview(for: pr))
            }
            await task.value
            if case .done(let text) = state(for: pr) {
                let s = savedReview(for: pr)
                ReviewPage.open(pr: pr, text: text, label: s.map(ReviewPage.label), date: s?.date)
            }
        }
    }

    @discardableResult
    private func run(_ pr: PR, since earlier: SavedReview?) -> Task<Void, Never> {
        let key = pr.reviewKey
        let previous = reviews[key]
        reviews[key] = .running
        let task = Task {
            defer { running[key] = nil }
            do {
                let by = Agent.current.label(Agent.current.review)
                var sinceCommit: String?, fellBack: Bool?
                let text: String
                if let earlier {
                    let r = try await Backend.reviewChanges(pr, since: earlier)
                    text = r.text
                    sinceCommit = earlier.pr.versionLabel
                    fellBack = r.fellBack
                } else {
                    text = try await Backend.review(pr)
                }
                reviews[pr.reviewKey] = .done(text)
                persist(pr, text, producedBy: by, sinceCommit: sinceCommit, fellBack: fellBack)
            } catch is CancellationError {
                reviews[pr.reviewKey] = previous
            } catch {
                // A failed re-run must not hide the review that is still saved.
                if case .done = previous {
                    reviews[pr.reviewKey] = previous
                    self.error = "Re-run failed: \(error.localizedDescription)"
                } else {
                    reviews[pr.reviewKey] = .failed(error.localizedDescription)
                }
            }
        }
        running[key] = task
        return task
    }

    private func persist(_ pr: PR, _ text: String, producedBy: String,
                         sinceCommit: String? = nil, fellBack: Bool? = nil) {
        saved.removeAll { $0.id == pr.reviewKey }
        saved.insert(SavedReview(pr: pr, text: text, date: Date(), producedBy: producedBy,
                                 sinceCommit: sinceCommit, sinceFellBack: fellBack), at: 0)
        Store.save(saved)
        Store.writeMarkdown(pr, text)
    }

    func delete(_ s: SavedReview) {
        saved.removeAll { $0.id == s.id }
        reviews[s.id] = nil
        Store.save(saved)
        Store.deleteMarkdown(s.pr)
    }

    /// Notes for this exact version, else the newest saved review of the same PR.
    private func priorNotes(for pr: PR) -> String? {
        if case .done(let text) = state(for: pr) { return text }
        return saved.first { $0.pr.url == pr.url }?.text
    }

    /// True if Terminal should open a follow-up (saved notes or replies exist) rather than a fresh review.
    func hasFollowUpContext(_ pr: PR) -> Bool {
        priorNotes(for: pr) != nil || replies.contains { $0.pr.url == pr.url }
    }

    /// The saved review for this exact version, if any.
    func savedReview(for pr: PR) -> SavedReview? { saved.first { $0.id == pr.reviewKey } }

    // MARK: Quick summaries

    /// Summaries are offered where there are comments to read: replies to you, or your own PRs.
    func canSummarise(_ pr: PR) -> Bool {
        isMine(pr) || replies.contains { $0.pr.url == pr.url }
    }

    /// Changes when new comments arrive, so an old summary isn't shown as current.
    private func summaryKey(_ pr: PR) -> String {
        let latest = myPRs.first { $0.pr.url == pr.url }?.latestAt
            ?? replies.first { $0.pr.url == pr.url }?.latestAt ?? ""
        return pr.url + "#" + latest
    }

    func summaryState(for pr: PR) -> ReviewState { summaries[summaryKey(pr)] ?? .idle }

    private func summaryText(for pr: PR) -> String? {
        if case .done(let text) = summaryState(for: pr) { return text }
        return nil
    }

    func summarise(_ pr: PR) {
        let key = summaryKey(pr)
        let mine = isMine(pr)
        summaries[key] = .running
        Task {
            do {
                let text = try await Backend.summariseFeedback(pr, mine: mine)
                summaries[key] = .done(text)
            } catch {
                summaries[key] = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Terminal

    /// Your own PR: work through feedback. Otherwise a fresh review, or a follow-up
    /// seeded with saved notes and the feedback on GitHub. A quick summary, if one
    /// was made, is handed over as a starting point.
    func openTerminal(_ pr: PR) {
        let mode: Backend.TerminalMode
        if isMine(pr) {
            mode = .author(summary: summaryText(for: pr))
        } else if hasFollowUpContext(pr) {
            mode = .followUp(notes: priorNotes(for: pr), summary: summaryText(for: pr))
        } else {
            mode = .review
        }
        launchTerminal(pr, mode: mode)
    }

    /// Your Verify command (Settings › Terminal) in the PR's worktree.
    func verifyInTerminal(_ pr: PR) {
        guard let command = ClaudeSettings.verifyCommand(for: pr.url) else { return }
        launchTerminal(pr, mode: .verify(command: command))
    }

    private func launchTerminal(_ pr: PR, mode: Backend.TerminalMode) {
        terminalNotice = nil
        Task {
            do {
                if let command = try await Backend.openInTerminal(pr, mode: mode) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    terminalNotice = "Command copied. Paste it into any terminal to start the session."
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
