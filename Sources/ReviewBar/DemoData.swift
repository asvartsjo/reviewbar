import Foundation

/// Canned data for `--demo` (`swift run ReviewBar --demo`, or `open ReviewBar.app --args --demo`):
/// every Reviewing state without calling `gh`. Each refresh moves the story one step, up to the
/// last. Step 1 is the baseline. Step 2 pushes to #140, resolves your last thread on #160, adds an
/// approval on #152 and a new request (#180), so the blue dot, "mute until something happens" and
/// the notifications have something to react to. Reviews are never written to disk in demo mode.
enum DemoData {
    static let isOn = CommandLine.arguments.contains("--demo")
    static let lastStep = 2

    /// Thrown by actions that would reach GitHub, an agent or a terminal: the PRs are made up.
    struct Unavailable: LocalizedError {
        var errorDescription: String? { "Not in demo mode: these PRs are made up." }
    }

    /// 0 before the first refresh.
    @MainActor private(set) static var step = 0
    /// When each step began, so its events keep one time across refreshes.
    @MainActor private static var stepStarted: [Int: Date] = [:]

    @MainActor static func advance() {
        guard step < lastStep else { return }
        step += 1
        stepStarted[step] = Date()
    }

    // MARK: Lists

    /// Review requests (`Backend.fetchPRs`). #88 is also in `reviewing`, so it reads as a re-request.
    @MainActor static func requests(step s: Int = step) -> [PR] {
        var prs = [checkout, rateLimit, cart]
        if s >= 2 { prs.append(csvExport) }
        return prs
    }

    /// PRs you reviewed before (`Backend.fetchReviewing`); `Backend.merge` adds the requests.
    @MainActor static func reviewing(step s: Int = step) -> [ReviewingPR] {
        let pushedAt = s >= 2 ? iso(stepStarted[2] ?? Date()) : nil
        return [
            ReviewingPR(pr: cart, myLastReview: .init(state: "COMMENTED", commit: oid("88a"), at: ago(days: 3)),
                        waiting: 0, myThreads: 1, resolved: 1, outdated: 1, verdicts: [], checks: "SUCCESS",
                        latestAt: ago(hours: 20), lastOtherAt: ago(hours: 20)),
            ReviewingPR(pr: invoices, myLastReview: .init(state: "CHANGES_REQUESTED", commit: oid("120a"), at: ago(days: 2)),
                        waiting: 1, myThreads: 3, resolved: 1, outdated: 2,
                        verdicts: [.init(login: "omar", state: "APPROVED")], checks: "SUCCESS",
                        latestAt: ago(hours: 3), lastOtherAt: ago(hours: 3)),
            ReviewingPR(pr: debounce, myLastReview: .init(state: "COMMENTED", commit: oid("131a"), at: ago(days: 1)),
                        waiting: 2, myThreads: 3, resolved: 0, outdated: 0, verdicts: [], checks: "SUCCESS",
                        latestAt: ago(hours: 2), lastOtherAt: ago(hours: 2)),
            ReviewingPR(pr: webhooks(step: s), myLastReview: .init(state: "CHANGES_REQUESTED", commit: oid("140a"), at: ago(hours: 30)),
                        waiting: 0, myThreads: 2, resolved: 0, outdated: 0,
                        verdicts: [.init(login: "lina", state: "CHANGES_REQUESTED")], checks: s >= 2 ? "PENDING" : "SUCCESS",
                        latestAt: ago(hours: 26), lastOtherAt: ago(hours: 26)),
            ReviewingPR(pr: footer, myLastReview: .init(state: "APPROVED", commit: oid("152a"), at: ago(days: 2)),
                        waiting: 0, myThreads: 0, resolved: 0, outdated: 0,
                        verdicts: s >= 2 ? [.init(login: "omar", state: "APPROVED")] : [], checks: "SUCCESS",
                        latestAt: pushedAt ?? footer.updatedAt, lastOtherAt: pushedAt),
            ReviewingPR(pr: queue, myLastReview: .init(state: "COMMENTED", commit: oid("160a"), at: ago(days: 4)),
                        waiting: 0, myThreads: 2, resolved: s >= 2 ? 2 : 1, outdated: 0, verdicts: [], checks: "SUCCESS",
                        latestAt: ago(days: 3), lastOtherAt: ago(days: 3)),
            ReviewingPR(pr: productPage, myLastReview: .init(state: "COMMENTED", commit: oid("170a"), at: ago(days: 5)),
                        waiting: 0, myThreads: 1, resolved: 0, outdated: 1, verdicts: [], checks: "FAILURE",
                        latestAt: ago(hours: 6), lastOtherAt: ago(hours: 6)),
            ReviewingPR(pr: tokens, myLastReview: .init(state: "APPROVED", commit: nil, at: ago(days: 6)),
                        waiting: 0, myThreads: 0, resolved: 0, outdated: 0, verdicts: [], checks: nil,
                        latestAt: ago(hours: 8), lastOtherAt: ago(hours: 8)),
        ]
    }

    /// Answers in your threads (`Backend.fetchReplies`): the reply banner and follow-up terminal mode.
    static func replies() -> [ReplyPR] {
        [ReplyPR(pr: invoices, waiting: 1, latestAt: ago(hours: 3), latestBy: "lina"),
         ReplyPR(pr: debounce, waiting: 2, latestAt: ago(hours: 2), latestBy: "sam")]
    }

    /// Your own PRs (`Backend.fetchMyPRs`): a merge conflict, one ready to merge, and a new one
    /// nobody has looked at yet.
    static func myPRs() -> [FeedbackPR] {
        [FeedbackPR(pr: pr("acme/storefront", 300, "Settings: dark mode", by: "you", head: "300a", openedDaysAgo: 4),
                    decision: "CHANGES_REQUESTED", threads: 2, reviews: 1, comments: 1,
                    latestAt: ago(hours: 4), latestBy: "lina", checks: "SUCCESS", mergeable: "CONFLICTING",
                    hasFeedback: true),
         FeedbackPR(pr: pr("acme/api", 305, "Bump Swift to 6.1", by: "you", head: "305a", openedDaysAgo: 2),
                    decision: "APPROVED", threads: 0, reviews: 1, comments: 0,
                    latestAt: ago(days: 1), latestBy: "omar", checks: "SUCCESS", mergeable: "MERGEABLE",
                    hasFeedback: true),
         FeedbackPR(pr: pr("acme/api", 310, "Log slow queries", by: "you", head: "310a", openedDaysAgo: 0.02),
                    decision: "REVIEW_REQUIRED", threads: 0, reviews: 0, comments: 0,
                    latestAt: "", latestBy: "", checks: "PENDING", mergeable: "MERGEABLE"),
         FeedbackPR(pr: pr("acme/api", 312, "Export grades as CSV", by: "you", head: "312a", openedDaysAgo: 1, draft: true),
                    decision: "REVIEW_REQUIRED", threads: 0, reviews: 0, comments: 0,
                    latestAt: "", latestBy: "", checks: "SUCCESS", mergeable: "MERGEABLE"),
         FeedbackPR(pr: pr("acme/storefront", 314, "Retry failed webhooks", by: "you", head: "314a", openedDaysAgo: 3),
                    decision: "REVIEW_REQUIRED", threads: 0, reviews: 0, comments: 0,
                    latestAt: "", latestBy: "", checks: "SUCCESS", mergeable: "MERGEABLE", botThreads: 2),
         FeedbackPR(pr: PR(number: 290, title: "Spike: offline mode", url: "https://github.com/acme/storefront/pull/290",
                           isDraft: true, updatedAt: ago(days: 45), repository: .init(nameWithOwner: "acme/storefront"),
                           author: .init(login: "you"), headRefOid: oid("290a"), createdAt: ago(days: 60)),
                    decision: "REVIEW_REQUIRED", threads: 0, reviews: 0, comments: 0,
                    latestAt: "", latestBy: "", checks: "SUCCESS", mergeable: "MERGEABLE")]
    }

    static func mentions() -> [Mention] {
        [Mention(repo: "acme/api", number: 214, title: rateLimit.title, author: "omar",
                 snippet: "@you does this match what we agreed for the partner API?",
                 url: rateLimit.url + "#issuecomment-1", updatedAt: ago(hours: 5))]
    }

    /// Reviews saved in ReviewBar: ✨ on #152 (this version), 🕘 on #88 (an older one).
    static var saved: [SavedReview] {
        [SavedReview(pr: footer, text: """
            VERDICT: Approve — only links and copy change.

            ## Good
            - Links point at the new legal pages.
            """, date: Date().addingTimeInterval(-2 * day), producedBy: "sonnet · medium"),
         SavedReview(pr: pr("acme/storefront", 88, cart.title, by: "sam", head: "88a", openedDaysAgo: 8), text: """
            VERDICT: Comment — works, but the saved cart is never cleared.

            ## Findings
            ### [question] `Sources/Cart/CartStore.swift:42` When is the saved cart cleared?
            Why: it's written on every change and only read on launch.
            > question: Is the saved cart cleared after checkout, or does it come back on the next visit?

            ### [nit] `Sources/Cart/CartStore.swift:57` Unused import

            ## Good
            - Small, focused change with a test.
            """, date: Date().addingTimeInterval(-3 * day), producedBy: "sonnet · high")]
    }

    // MARK: Detail

    /// What `Backend.fetchReviewingDetail` would load when you open the PR.
    @MainActor static func detail(for r: ReviewingPR, step s: Int = step) -> ReviewingDetail {
        typealias Thread = ReviewingDetail.MyThread
        func thread(_ path: String, _ line: Int, _ title: String, _ body: String,
                    _ state: Thread.State, outdated: Bool = false) -> Thread {
            Thread(path: path, line: line, snippet: title, fullText: title + "\n\n" + body,
                   url: r.pr.url + "#discussion_r\(line)", state: state, isOutdated: outdated)
        }
        func did(_ login: String, _ kind: ReviewingDetail.Activity.Kind, _ at: String) -> ReviewingDetail.Activity {
            .init(login: login, kind: kind, at: at, url: r.pr.url)
        }
        func commits(_ messages: [String]) -> ReviewingDetail.Commits {
            .new(count: messages.count, commits: messages.enumerated().map {
                .init(sha: String(oid("\(r.pr.number)c\($0.offset)").prefix(7)), message: $0.element)
            })
        }

        switch r.pr.number {
        case 88:
            return ReviewingDetail(commits: commits(["Clear the saved cart after checkout"]),
                myThreads: [thread("Sources/Cart/CartStore.swift", 42, "❓ When is the saved cart cleared?",
                                   "It's written on every change and only read on launch.", .resolved, outdated: true)],
                openThreadsBy: [:],
                activity: [did("sam", .reviewRequested(from: nil), ago(hours: 20))])
        case 120:
            return ReviewingDetail(commits: commits(["Round totals per invoice", "Name the PDF after the invoice number"]),
                myThreads: [
                    thread("app/Invoices/PdfExport.php", 88, "🔴 Totals are rounded per line, not per invoice",
                           "Ten lines of 0.005 add up to a 5-cent difference.", .replied(by: "lina"), outdated: true),
                    thread("app/Invoices/PdfExport.php", 31, "🟡 Name the file after the invoice number",
                           "invoice.pdf in Downloads is hard to find.", .open, outdated: true),
                    thread("app/Invoices/Policy.php", 12, "❓ Should drafts be exportable?",
                           "Accountants might send a draft by mistake.", .resolved),
                ],
                openThreadsBy: [:],
                activity: [did("lina", .replied(threads: 1), ago(hours: 3)),
                           did("omar", .approved, ago(hours: 5))])
        case 131:
            return ReviewingDetail(commits: .same,
                myThreads: [
                    thread("src/search/useSearch.ts", 24, "🚨 Old requests aren't cancelled",
                           "A slow response for \"sh\" can overwrite the results for \"shoes\".", .replied(by: "sam")),
                    thread("src/search/useSearch.ts", 9, "🟠 300 ms feels slow on desktop",
                           "Maybe 150 ms, or leading-edge?", .replied(by: "sam")),
                    thread("src/search/SearchBox.vue", 5, "🟡 Typo in the placeholder",
                           "\"Serach products\"", .open),
                ],
                openThreadsBy: [:],
                activity: [did("sam", .replied(threads: 2), ago(hours: 2))])
        case 140:
            return ReviewingDetail(commits: s >= 2 ? commits(["Sign with HMAC-SHA256 and rotate keys"]) : .same,
                myThreads: [
                    thread("app/Webhooks/Dispatcher.php", 51, "🔴 The secret is logged on failure",
                           "The whole request, headers included, goes to the log.", .open),
                    thread("app/Webhooks/Dispatcher.php", 77, "🟠 No timestamp in the signature",
                           "Without it a captured payload can be replayed.", .open),
                ],
                openThreadsBy: ["lina": 1],
                activity: [did("lina", .changesRequested(comments: 1), ago(hours: 26))])
        case 152:
            return ReviewingDetail(commits: .same, myThreads: [], openThreadsBy: [:],
                activity: s >= 2 ? [did("omar", .approved, iso(stepStarted[2] ?? Date()))] : [])
        case 160:
            return ReviewingDetail(commits: .same,
                myThreads: [
                    thread("app/Jobs/SendReminders.php", 18, "🟡 Log the job id", "Makes failed runs traceable.",
                           s >= 2 ? .resolved : .open),
                    thread("app/Jobs/SendReminders.php", 40, "🟠 Retries need a backoff",
                           "Three instant retries hit the same outage.", .resolved),
                ],
                openThreadsBy: [:], activity: [])
        case 170:
            return ReviewingDetail(commits: .rebased,
                myThreads: [thread("src/product/ProductPage.vue", 140, "🟡 This watcher never stops",
                                   "It runs after the page is left.", .open, outdated: true)],
                openThreadsBy: [:],
                activity: [did("omar", .forcePushed(times: 2), ago(hours: 6))])
        case 175:
            return ReviewingDetail(commits: .gone, myThreads: [], openThreadsBy: [:],
                activity: [did("lina", .commented, ago(hours: 8)),
                           did("lina", .convertedToDraft, ago(hours: 9)),
                           did("lina", .forcePushed(times: 1), ago(hours: 10)),
                           did("lina", .dismissedReview(of: nil), ago(hours: 10))])
        default:
            return ReviewingDetail(commits: .unknown, myThreads: [], openThreadsBy: [:])
        }
    }

    // MARK: PRs

    private static let checkout = pr("acme/storefront", 101, "Checkout: retry failed card payments",
                                     by: "lina", head: "101a", openedDaysAgo: 5, checks: "FAILURE")
    private static let rateLimit = pr("acme/api", 214, "Rate-limit the public endpoints",
                                      by: "omar", head: "214a", openedDaysAgo: 1, checks: "PENDING")
    private static let cart = pr("acme/storefront", 88, "Cart: keep items between sessions",
                                 by: "sam", head: "88b", openedDaysAgo: 8)
    private static let invoices = pr("acme/api", 120, "Invoices: PDF export", by: "lina", head: "120b", openedDaysAgo: 6)
    private static let debounce = pr("acme/storefront", 131, "Search: debounce the query input",
                                     by: "sam", head: "131a", openedDaysAgo: 3)
    private static func webhooks(step s: Int) -> PR {
        pr("acme/api", 140, "Webhooks: sign payloads", by: "omar", head: s >= 2 ? "140b" : "140a", openedDaysAgo: 4)
    }
    private static let footer = pr("acme/storefront", 152, "Footer: update legal links", by: "lina", head: "152a", openedDaysAgo: 3)
    private static let queue = pr("acme/api", 160, "Move cron jobs to the queue", by: "sam", head: "160a", openedDaysAgo: 9)
    private static let productPage = pr("acme/storefront", 170, "Product page: split into components",
                                        by: "omar", head: "170c", openedDaysAgo: 12)
    private static let tokens = pr("acme/api", 175, "Auth: refresh tokens before they expire",
                                   by: "lina", head: "175b", openedDaysAgo: 10, draft: true)
    private static let csvExport = pr("acme/api", 180, "Orders: export as CSV", by: "sam", head: "180a", openedDaysAgo: 0)

    private static func pr(_ repo: String, _ number: Int, _ title: String, by author: String, head: String,
                           openedDaysAgo: Double, checks: String? = "SUCCESS", draft: Bool = false) -> PR {
        PR(number: number, title: title, url: "https://github.com/\(repo)/pull/\(number)", isDraft: draft,
           updatedAt: ago(hours: 1), repository: .init(nameWithOwner: repo), author: .init(login: author),
           headRefOid: oid(head), createdAt: ago(days: openedDaysAgo), checks: checks)
    }

    // MARK: Time and commits

    /// Fixed at launch, so times don't move between refreshes (a moving time would count as new).
    private static let launched = Date()
    private static let day: TimeInterval = 86_400

    private static func ago(days: Double = 0, hours: Double = 0) -> String {
        iso(launched.addingTimeInterval(-(days * day + hours * 3_600)))
    }

    private static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    /// A 40-character commit id starting with `tag`.
    private static func oid(_ tag: String) -> String { tag.padding(toLength: 40, withPad: "0", startingAt: 0) }
}
