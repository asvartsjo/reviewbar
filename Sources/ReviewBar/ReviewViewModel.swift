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
    /// The last Reviewing fetch that succeeded, so requests still show when a later one fails.
    private var reviewed: [ReviewingPR] = []
    @Published var myPRs: [FeedbackPR] = []
    /// Shown under the terminal button, e.g. after copying a command.
    @Published var terminalNotice: String?
    /// Quick-model summaries, keyed by `summaryKey` so newer comments make them stale. Not saved.
    @Published var summaries: [String: ReviewState] = [:]
    /// PR url -> `latestAt` of the reply you dismissed. Newer replies bring the PR back.
    @Published private var dismissed: [String: String] =
        UserDefaults.standard.dictionary(forKey: "dismissedReplies") as? [String: String] ?? [:]
    private var timer: Timer?
    private var crewTimer: Timer?
    /// Every Claude session in my watched repos, idle ones too, waiting on me first.
    @Published private(set) var allCrew: [CrewItem] = []
    /// The sessions Crew shows and counts: waiting on me or working.
    var crew: [CrewItem] { allCrew.filter { !$0.session.idle } }
    /// Idle sessions, folded under Crew: one can live on with no visible window.
    var idleCrew: [CrewItem] { allCrew.filter(\.session.idle) }
    /// PR url → when ReviewBar last opened a session on it, for the second-session check.
    private var launchedAt: [String: Date] = [:]
    /// Ids of the sessions that were waiting on me at the last poll; nil until the first one.
    private var crewWaiting: Set<String>?
    private var lastRefresh: Date?
    private var refreshAgain = false
    /// What the previous successful refresh saw, per list; nil until the first one (the baseline).
    private var seenRequests: Set<String>?
    private var seenReplies: [String: String]?
    private var seenFeedback: [String: String]?
    private var seenReviewing: [String: ReviewingPR]?
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
        crewTimer = Timer.scheduledTimer(withTimeInterval: Crew.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshCrew() }
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
        seenReviewing = nil
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
        if DemoData.isOn { DemoData.advance() }
        let skip = skippedRepos
        async let fetchedPRs = Backend.fetchPRs(skipping: skip)
        async let fetchedReplies = Backend.fetchReplies(skipping: skip)
        async let fetchedReviewing = Backend.fetchReviewing(skipping: skip)
        async let fetchedMine = Backend.fetchMyPRs(skipping: skip)
        let week = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-7 * 86_400))
        async let fetchedMentions = Backend.fetchMentions(since: week, repos: RepoList.load())
        var errors: [String] = []
        var alerts: [ReviewAlert] = []
        var freshRequests: [PR] = []
        var repliesLoaded = false

        // Each list only updates (and only notifies) when its own fetch succeeded; Reviewing
        // still takes in the latest requests.
        do {
            prs = PRFilter.others(try await fetchedPRs, includeDrafts: PRFilter.includeDrafts)
            freshRequests = AlertDiff.newRequests(prs, seen: seenRequests)
            if AutoReview.isOn, !DemoData.isOn { autoReview(freshRequests) }
            seenRequests = Set(prs.map(\.url))
        } catch { errors.append(error.localizedDescription) }
        do {
            replies = PRFilter.others(try await fetchedReplies, includeDrafts: PRFilter.includeDrafts)
            alerts += AlertDiff.newer(visibleReplies, seen: seenReplies, url: \.pr.url, latestAt: \.latestAt)
                .map(ReviewAlert.reply)
            seenReplies = AlertDiff.latestByURL(replies, url: \.pr.url, latestAt: \.latestAt)
            repliesLoaded = true
        } catch { errors.append("Thread replies: \(error.localizedDescription)") }
        var reviewingLoaded = false
        do {
            reviewed = PRFilter.others(try await fetchedReviewing, includeDrafts: PRFilter.includeDrafts)
            reviewingLoaded = true
        } catch { errors.append("Reviewing: \(error.localizedDescription)") }
        reviewing = Backend.merge(reviewed, requested: prs)
        if reviewingLoaded {
            alerts += AlertDiff.reviewing(reviewing.filter { !mutedForever.contains($0.pr.url) }, before: seenReviewing)
            seenReviewing = Dictionary(reviewing.map { ($0.pr.url, $0) }, uniquingKeysWith: { a, _ in a })
            updateSeen()
            if repliesLoaded { migrateReplyDismissals() }
        }
        // After Reviewing, so a request on a PR you reviewed reads as a re-request.
        let reviewedURLs = Set(reviewing.filter { $0.myLastReview != nil }.map(\.pr.url))
        alerts += AlertDiff.requests(freshRequests, reviewed: reviewedURLs)
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
        removeClosedWorktreesDaily()
        Task { await refreshCrew() }
        loading = false
        if refreshAgain {
            refreshAgain = false
            await refresh()
        }
    }

    private static let worktreeCleanupKey = "worktreeCleanupAt"

    /// At most once a day, in the background: remove worktrees of merged or closed PRs. The day
    /// starts before the run, so a failure waits until tomorrow. Never in demo mode.
    private func removeClosedWorktreesDaily() {
        guard !DemoData.isOn else { return }
        let last = UserDefaults.standard.object(forKey: Self.worktreeCleanupKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 86_400 else { return }
        UserDefaults.standard.set(Date(), forKey: Self.worktreeCleanupKey)
        let repos = RepoList.load()
        Task.detached(priority: .background) { await Backend.removeClosedWorktrees(repos: repos) }
    }

    /// Replies for notifications and the PR detail: not dismissed (or newer than what you
    /// dismissed) and not on a PR muted for good.
    var visibleReplies: [ReplyPR] {
        replies.filter { $0.latestAt > (dismissed[$0.pr.url] ?? "") && !mutedForever.contains($0.pr.url) }
    }

    /// Nil while the PR is muted.
    func reply(for pr: PR) -> ReplyPR? {
        if let r = reviewingPR(for: pr), isMuted(r) { return nil }
        return visibleReplies.first { $0.pr.url == pr.url }
    }

    func dismissReplies(_ r: ReplyPR) { dismiss(r.pr.url, until: r.latestAt) }

    var reviewingSections: [(group: ReviewingPR.Group, prs: [ReviewingPR])] {
        ReviewingPR.sections(reviewing, muted: isMuted)
    }

    var yourTurnCount: Int { reviewing.filter { $0.group == .yours && !isMuted($0) }.count }

    func reviewingPR(for pr: PR) -> ReviewingPR? { reviewing.first { $0.pr.url == pr.url } }

    /// Verify fixes is the next step: you have threads here, something changed since your review,
    /// and a Verify command is set. Then it's the one prominent button in the PR detail.
    func verifyIsDue(_ pr: PR) -> Bool {
        guard Agent.current == .claude, ClaudeSettings.verifyCommand(for: pr.url) != nil,
              let r = reviewingPR(for: pr), r.verifyIsDue,
              let d = detailLoad(for: pr).detail else { return false }
        return !d.myThreads.isEmpty
    }

    // MARK: New since you last looked

    private static let seenKey = "reviewingSeen", seenSeededKey = "reviewingSeenSeeded"
    private static let lastListedKey = "reviewingLastListed"
    /// PR url -> when you last opened it, and its head then. Survives restarts.
    @Published private var seen = loadSnapshots(seenKey)
    /// PR url -> when a Reviewing fetch last listed it, for PRs with a seen or mute snapshot.
    private var lastListed = UserDefaults.standard.dictionary(forKey: lastListedKey) as? [String: String] ?? [:]
    /// The snapshot each PR had before this session's latest opening, for the open detail.
    private var seenBefore: [String: PRSnapshot] = [:]

    /// Changed since you last opened it; a PR you never opened is new.
    func isNew(_ r: ReviewingPR) -> Bool { seen[r.pr.url].map { r.changed(since: $0) } ?? true }

    /// When you looked before opening this PR now; nil the first time.
    func previouslySeen(_ pr: PR) -> String? { seenBefore[pr.url]?.at }

    func markSeen(_ r: ReviewingPR) {
        let url = r.pr.url
        seenBefore[url] = seen[url]
        seen[url] = PRSnapshot(at: Self.isoNow(), head: r.pr.headRefOid)
        saveSeen()
    }

    /// After a successful Reviewing fetch: the first time there is a list, record every listed PR
    /// so they don't all start as new; after that, forget PRs gone from the list for a month.
    /// Skipped in demo mode, so demo PRs start as new and real snapshots are never pruned.
    private func updateSeen() {
        guard !DemoData.isOn else { return }
        let now = Self.isoNow()
        if !UserDefaults.standard.bool(forKey: Self.seenSeededKey), !reviewing.isEmpty {
            for r in reviewing where seen[r.pr.url] == nil { seen[r.pr.url] = PRSnapshot(at: now, head: r.pr.headRefOid) }
            UserDefaults.standard.set(true, forKey: Self.seenSeededKey)
        }
        let month = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-30 * 86_400))
        let listed = Set(reviewing.map(\.pr.url))
        for url in listed { lastListed[url] = now }
        seen = PRSnapshot.pruned(seen, listed: listed, lastListed: lastListed, cutoff: month)
        mutedUntil = PRSnapshot.pruned(mutedUntil, listed: listed, lastListed: lastListed, cutoff: month)
        lastListed = lastListed.filter { seen[$0.key] != nil || mutedUntil[$0.key] != nil }
        saveSeen()
        Self.saveSnapshots(mutedUntil, Self.mutedUntilKey)
        UserDefaults.standard.set(lastListed, forKey: Self.lastListedKey)
    }

    private func saveSeen() { Self.saveSnapshots(seen, Self.seenKey) }

    private static func loadSnapshots(_ key: String) -> [String: PRSnapshot] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: PRSnapshot].self, from: data)) ?? [:]
    }

    /// Not in demo mode: its made-up PRs would stay in your settings for good.
    private static func saveSnapshots(_ s: [String: PRSnapshot], _ key: String) {
        guard !DemoData.isOn else { return }
        if let data = try? JSONEncoder().encode(s) { UserDefaults.standard.set(data, forKey: key) }
    }

    private static func isoNow() -> String { ISO8601DateFormatter().string(from: Date()) }

    // MARK: Mute

    private static let mutedUntilKey = "reviewingMutedUntil", mutedForeverKey = "reviewingMutedForever"
    /// PR url -> the moment you muted it: it comes back when something changes after that.
    @Published private var mutedUntil = loadSnapshots(mutedUntilKey)
    /// PRs muted for good: no new-commits, resolved or verdict notifications either.
    @Published private var mutedForever = Set(UserDefaults.standard.stringArray(forKey: mutedForeverKey) ?? [])

    func isMuted(_ r: ReviewingPR) -> Bool {
        r.isMuted(forever: mutedForever.contains(r.pr.url), until: mutedUntil[r.pr.url])
    }

    func muteUntilSomethingHappens(_ r: ReviewingPR) {
        mutedUntil[r.pr.url] = PRSnapshot(at: Self.isoNow(), head: r.pr.headRefOid)
        Self.saveSnapshots(mutedUntil, Self.mutedUntilKey)
    }

    func muteForGood(_ r: ReviewingPR) {
        mutedForever.insert(r.pr.url)
        saveMutedForever()
    }

    private static let migratedDismissalsKey = "reviewingMigratedReplyDismissals"

    /// Once: Replies dismissals that still hide a reply become mutes, now that Reviewing
    /// replaces the Replies tab.
    private func migrateReplyDismissals() {
        guard !DemoData.isOn else { return }
        guard !UserDefaults.standard.bool(forKey: Self.migratedDismissalsKey) else { return }
        let mutes = PRSnapshot.mutes(fromDismissed: dismissed, replies: replies, reviewing: reviewing)
        mutedUntil.merge(mutes) { current, _ in current }
        Self.saveSnapshots(mutedUntil, Self.mutedUntilKey)
        UserDefaults.standard.set(true, forKey: Self.migratedDismissalsKey)
    }

    private func saveMutedForever() {
        guard !DemoData.isOn else { return }
        UserDefaults.standard.set(Array(mutedForever), forKey: Self.mutedForeverKey)
    }

    func unmute(_ r: ReviewingPR) {
        mutedUntil[r.pr.url] = nil
        mutedForever.remove(r.pr.url)
        Self.saveSnapshots(mutedUntil, Self.mutedUntilKey)
        saveMutedForever()
    }

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
    /// Quiet PRs have no `latestAt`, so they're never in it.
    var visibleFeedback: [FeedbackPR] {
        myPRs.filter { $0.latestAt > (dismissed[$0.pr.url] ?? "") && !parked.contains($0.pr.url) }
    }

    func feedback(for pr: PR) -> FeedbackPR? { visibleFeedback.first { $0.pr.url == pr.url } }

    /// My PRs by whose move it is: Your move, Waiting on others, Parked.
    var mySections: [(group: MyGroup, prs: [FeedbackPR])] {
        MyGroup.sections(myPRs, dismissed: dismissed, parked: parked)
    }

    private static let parkedKey = "myPRsParked"
    /// My PRs parked by hand: listed under Parked, never notify or count, until unparked.
    @Published private var parked = Set(UserDefaults.standard.stringArray(forKey: parkedKey) ?? [])

    func isParked(_ f: FeedbackPR) -> Bool { parked.contains(f.pr.url) }

    func park(_ f: FeedbackPR) {
        parked.insert(f.pr.url)
        saveParked()
    }

    func unpark(_ f: FeedbackPR) {
        parked.remove(f.pr.url)
        saveParked()
    }

    private func saveParked() {
        guard !DemoData.isOn else { return }
        UserDefaults.standard.set(Array(parked), forKey: Self.parkedKey)
    }

    var yourMoveCount: Int { mySections.first { $0.group == .yours }?.prs.count ?? 0 }

    /// True for your own open PRs.
    func isMine(_ pr: PR) -> Bool { myPRs.contains { $0.pr.url == pr.url } }

    func dismissFeedback(_ f: FeedbackPR) { dismiss(f.pr.url, until: f.latestAt) }

    private func dismiss(_ url: String, until latestAt: String) {
        dismissed[url] = latestAt
        guard !DemoData.isOn else { return }
        UserDefaults.standard.set(dismissed, forKey: "dismissedReplies")
    }

    /// Distinct PRs needing you, from what Settings › Menu bar number picks: Reviewing's Your turn
    /// (split into review requests and activity on PRs you reviewed; not muted), feedback on your
    /// PRs, and mentions.
    var badgeCount: Int {
        MenuBarCount.count(yourTurn: reviewing.filter { $0.group == .yours && !isMuted($0) },
                           feedback: visibleFeedback.map(\.pr.url), mentions: visibleMentions,
                           crew: crew.filter(\.session.needsMe).map(\.id), counting: .current)
    }

    func state(for pr: PR) -> ReviewState { reviews[pr.reviewKey] ?? .idle }

    /// True if an older review of this PR exists (the PR has new activity since).
    func hasOlderReview(_ pr: PR) -> Bool {
        saved.contains { $0.pr.url == pr.url && $0.id != pr.reviewKey }
    }

    /// The newest review of an earlier version of this PR, whether or not it recorded its commit.
    func olderReview(for pr: PR) -> SavedReview? {
        saved.first { $0.pr.url == pr.url && $0.id != pr.reviewKey }
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

    /// PRs "Review all" would pick up: not muted, no review of this version yet, and none running.
    var unreviewed: [PR] {
        prs.filter { pr in
            if let r = reviewingPR(for: pr), isMuted(r) { return false }
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
                // Open the PR's files page, where the pending review can be submitted or discarded.
                if error is Backend.PendingReviewExists, let u = URL(string: pr.url + "/files") {
                    NSWorkspace.shared.open(u)
                }
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

    /// Summaries are offered where there are comments to read: replies to you, your own PRs
    /// with feedback, or a PR where others spoke after your review.
    func canSummarise(_ pr: PR) -> Bool {
        myPRs.contains { $0.pr.url == pr.url && $0.hasFeedback } || replies.contains { $0.pr.url == pr.url } || summarySince(pr) != nil
    }

    /// Your last review, when others spoke after it: the summary then covers what happened since.
    func summarySince(_ pr: PR) -> String? {
        guard !isMine(pr), let r = reviewingPR(for: pr), r.othersSpokeSinceReview else { return nil }
        return r.myLastReview?.at
    }

    /// Changes when new comments arrive, so an old summary isn't shown as current.
    private func summaryKey(_ pr: PR) -> String {
        // A quiet PR has no `latestAt`; `updatedAt` still moves with every comment or push.
        let latest = myPRs.first { $0.pr.url == pr.url }.map { $0.latestAt.isEmpty ? $0.pr.updatedAt : $0.latestAt }
            ?? [replies.first { $0.pr.url == pr.url }?.latestAt, reviewingPR(for: pr)?.latestAt].compactMap { $0 }.max()
            ?? ""
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
        let since = summarySince(pr)
        summaries[key] = .running
        Task {
            do {
                let text = try await Backend.summariseFeedback(pr, mine: mine, since: since)
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

    /// The next step on one of my PRs, from its move and my commands; Claude Code only.
    func myPRAction(for pr: PR) -> MyPRAction? {
        guard Agent.current == .claude, let f = myPRs.first(where: { $0.pr.url == pr.url }) else { return nil }
        return MyPRAction.for(f, feedbackCommand: ClaudeSettings.myPRCommand(for: pr.url),
                              mergeCommand: ClaudeSettings.mergeCommand(for: pr.url))
    }

    /// Runs `myPRAction` in the checkout of the PR's branch. With no such checkout nothing opens: the
    /// command is copied instead, since starting it anywhere else would commit in the wrong place.
    func runMyPRAction(_ pr: PR) {
        guard let action = myPRAction(for: pr), let f = myPRs.first(where: { $0.pr.url == pr.url }) else { return }
        terminalNotice = nil
        Task {
            if let branch = f.branch, let path = await Backend.checkout(of: branch, repo: pr.repository.nameWithOwner) {
                launchTerminal(pr, mode: .inCheckout(command: action.command, path: path))
            } else {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(action.command, forType: .string)
                terminalNotice = "No local checkout of \(f.branch ?? "this PR's branch"), so nothing was opened. "
                    + "The command is copied: run it where you have the branch."
            }
        }
    }

    /// A native alert, so it also shows when a notification's Verify fixes starts the session with
    /// the panel closed. Cancel is the default; Show session (third) only when a session is listed.
    private func askSecondSession(_ pr: PR, _ reason: String, canShow: Bool) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = "A Claude session is already open on #\(pr.number)"
        alert.informativeText = reason + "\n\nTwo sessions in one checkout can overwrite each other's edits "
            + "and draft duplicate replies."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Open anyway")
        if canShow { alert.addButton(withTitle: "Show session") }
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }

    /// Reads the crew again: local and cheap, so it runs every `Crew.pollInterval` and after each
    /// refresh. Claude Code only; a failed read keeps the last list.
    func refreshCrew() async {
        guard Agent.current == .claude else { allCrew = []; return }
        guard let fresh = DemoData.isOn ? DemoData.crew() : await Backend.crew(repos: RepoList.load(), myPRs: myPRs)
        else { return }
        for item in Crew.newlyWaiting(fresh, before: crewWaiting) { Notifier.crew(item, pr: pr(for: item)) }
        crewWaiting = Set(fresh.filter(\.session.needsMe).map(\.id))
        if fresh != allCrew { allCrew = fresh }
    }

    /// The crew session on this PR, one waiting on me first; nil when none.
    func crewItem(for pr: PR) -> CrewItem? {
        let mine = crew.filter {
            $0.prNumber == pr.number && $0.repo.lowercased() == pr.repository.nameWithOwner.lowercased()
        }
        return mine.first { $0.session.needsMe } ?? mine.first
    }

    /// The PR a crew session works on, if the app lists it.
    func pr(for item: CrewItem) -> PR? {
        guard let n = item.prNumber else { return nil }
        let match = { (p: PR) in p.number == n && p.repository.nameWithOwner.lowercased() == item.repo.lowercased() }
        return myPRs.first { match($0.pr) }?.pr ?? reviewing.first { match($0.pr) }?.pr
    }

    /// Stops a session (`Backend.stop`); its conversation is kept, so it can be resumed. A terminal
    /// session at work is asked about first: ending it mid-task can leave half-made edits.
    func stop(_ item: CrewItem) {
        guard !DemoData.isOn else { return }
        if !item.session.background, item.session.working {
            let alert = NSAlert()
            alert.messageText = "Stop \(item.session.displayName)? It's working."
            alert.informativeText = "Its conversation is kept (claude --resume), but an edit it's making may be left half done."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Stop")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        Task {
            if !(await Backend.stop(item.session)) {
                error = "Couldn't stop \(item.session.displayName). Try `claude stop \(item.session.id)` in a terminal."
            }
            await refreshCrew()
        }
    }

    /// Brings a session to the front: a background one with `claude attach`, a terminal one by
    /// selecting its tab in iTerm2 or Terminal. Other terminals can't be searched, so it says where.
    func show(_ item: CrewItem) {
        guard !DemoData.isOn else { return }
        if item.session.background { return attach(item) }
        terminalNotice = nil
        Task {
            let home = (item.session.cwd as NSString).abbreviatingWithTildeInPath
            if !(await Backend.reveal(item.session)) {
                terminalNotice = "Couldn't find \(item.session.displayName)'s window (iTerm2, Terminal and VS Code can be "
                    + "found). It runs in \(home)\(item.session.pid.map { ", pid \($0)" } ?? "")."
            } else if item.session.host == .vscode {
                terminalNotice = "Brought VS Code's window for \(home) to the front: \(item.session.displayName) is in its Claude Code panel."
            }
        }
    }

    /// `claude attach` for a background session, in the chosen terminal.
    func attach(_ item: CrewItem) {
        terminalNotice = nil
        Task {
            do {
                if let command = try await Backend.attach(item.session) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    terminalNotice = "Command copied. Paste it into any terminal to open the session."
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Your Verify command (Settings › Terminal) in the PR's worktree.
    func verifyInTerminal(_ pr: PR) {
        guard let command = ClaudeSettings.verifyCommand(for: pr.url) else { return }
        launchTerminal(pr, mode: .verify(command: command))
    }

    /// Opens the session, after asking first when one is already open on this PR: two sessions in
    /// one checkout overwrite each other's edits and draft duplicate replies. The crew is read again
    /// first, so the check is never 15 seconds stale.
    private func launchTerminal(_ pr: PR, mode: Backend.TerminalMode) {
        terminalNotice = nil
        // Recorded at the click, before anything waits: the terminal takes seconds to appear, and a
        // second click meanwhile must find this one.
        let previous = launchedAt[pr.url]
        launchedAt[pr.url] = Date()
        Task {
            await refreshCrew()
            let repo = pr.repository.nameWithOwner
            if let open = Crew.openSession(onPR: pr.number, repo: repo, crew: allCrew, launchedAt: previous) {
                let session = Crew.session(onPR: pr.number, repo: repo, crew: allCrew)
                switch askSecondSession(pr, open, canShow: session != nil) {
                case .alertSecondButtonReturn:
                    break
                case .alertThirdButtonReturn:
                    launchedAt[pr.url] = previous
                    if let session { show(session) }
                    return
                default:
                    launchedAt[pr.url] = previous
                    return
                }
            }
            let opening = "Opening a session in \(TerminalApp.chosen.name)…"
            if TerminalApp.chosen != .copy { terminalNotice = opening }
            do {
                if let command = try await Backend.openInTerminal(pr, mode: mode) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    terminalNotice = "Command copied. Paste it into any terminal to start the session."
                } else if terminalNotice == opening {
                    terminalNotice = nil
                }
            } catch {
                if terminalNotice == opening { terminalNotice = nil }
                self.error = error.localizedDescription
            }
        }
    }
}
