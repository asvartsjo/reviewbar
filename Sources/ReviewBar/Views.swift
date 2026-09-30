import SwiftUI
import AppKit
import ServiceManagement
import UserNotifications

private enum Tab: String, CaseIterable {
    case pending = "Awaiting me"
    case reviewing = "Reviewing"
    case replies = "Replies"
    case mine = "My PRs"
    case mentions = "Mentions"
    case saved = "Saved"
}

struct ContentView: View {
    @ViewState private var systemDark = ContentView.isSystemDark
    static var isSystemDark: Bool { UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" }
    @EnvironmentObject var vm: ReviewViewModel
    @ViewState private var showSettings = false
    @ViewState private var selected: PR?
    @ViewState private var tab: Tab = .pending

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if showSettings {
                SettingsView {
                    showSettings = false
                    Task { await vm.settingsChanged() }
                }
            } else if let pr = selected {
                DetailView(pr: pr) { selected = nil }
            } else {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text(title($0)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

                if let e = vm.error, tab != .saved {
                    Text(e).font(.caption).foregroundStyle(.red).padding(.horizontal, 10)
                }
                switch tab {
                case .pending: pendingList
                case .reviewing: reviewingList
                case .replies: repliesList
                case .mine: mineList
                case .mentions: mentionsList
                case .saved: savedList
                }
            }
        }
        .frame(minWidth: AsWindow.minimumSize.width, maxWidth: .infinity,
               minHeight: AsWindow.minimumSize.height, maxHeight: .infinity)
        // Solid, and follows the system Light/Dark setting rather than the menu bar's look.
        .background(systemDark ? Color(white: 0.11) : Color(white: 0.985))
        .environment(\.colorScheme, systemDark ? .dark : .light)
        .onReceive(DistributedNotificationCenter.default()
            .publisher(for: Notification.Name("AppleInterfaceThemeChangedNotification"))) { _ in
            systemDark = Self.isSystemDark
        }
        // Opening the popover refreshes data older than a minute.
        .onAppear { Task { await vm.refreshIfStale() } }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            Task { await vm.refreshIfStale() }
        }
    }

    // MARK: header

    private var header: some View {
        HStack {
            Text("Reviews").font(.headline)
            Spacer()
            if vm.loading { ProgressView().controlSize(.small) }
            Button { Task { await vm.refresh() } } label: { Image(systemName: "arrow.clockwise") }
            Button { showSettings.toggle() } label: { Image(systemName: "gearshape") }
            Button { NSApplication.shared.terminate(nil) } label: { Image(systemName: "power") }
        }
        .buttonStyle(.borderless)
        .padding(10)
    }

    // MARK: pending

    private var pendingList: some View {
        Group {
            if vm.prs.isEmpty && !vm.loading {
                empty("checkmark.circle", "Nothing waiting. Check settings if that looks wrong.")
            } else {
                reviewAllBar
                List(vm.prs) { pr in
                    Button { selected = pr } label: { row(pr) }.buttonStyle(.plain)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    @ViewBuilder private var reviewAllBar: some View {
        HStack {
            if let b = vm.batch {
                ProgressView(value: Double(b.done), total: Double(b.total)).frame(width: 120)
                Text("Reviewed \(b.done) of \(b.total)").font(.caption)
                Spacer()
                Button("Stop") { vm.cancelAll() }.font(.caption)
            } else if !vm.unreviewed.isEmpty {
                Text("\(vm.unreviewed.count) without a review").font(.caption)
                Spacer()
                Menu("Review all") {
                    Button("One by one") { vm.reviewAll(parallel: false) }
                    Button("In parallel (3 at a time)") { vm.reviewAll(parallel: true) }
                }
                .menuStyle(.borderlessButton).fixedSize().font(.caption)
            }
        }
        .padding(.horizontal, 10)
    }

    private func row(_ pr: PR) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(verbatim: "\(pr.repository.nameWithOwner) #\(pr.number)")
                    .font(.caption).foregroundStyle(.secondary)
                if pr.isDraft {
                    Text("DRAFT").font(.caption2).padding(.horizontal, 4)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                if case .done = vm.state(for: pr) {
                    Image(systemName: "sparkles").foregroundStyle(.orange)
                } else if vm.hasOlderReview(pr) {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                }
            }
            Text(pr.title).font(.body).lineLimit(2)
            HStack(spacing: 4) {
                Text("\(pr.author.login) · updated \(age(pr.updatedAt))")
                    .foregroundStyle(.secondary)
                if let opened = pr.createdAt {
                    let days = daysSince(opened)
                    Text(days < 1 ? "· opened today" : "· open \(days)d")
                        .foregroundStyle(days >= Self.oldAfterDays ? .orange : .secondary)
                        .help(days >= Self.oldAfterDays ? "Open for \(days) days" : "")
                }
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    // MARK: reviewing

    private var reviewingList: some View {
        Group {
            if vm.reviewing.isEmpty && !vm.loading {
                empty("eyeglasses", "No open PRs you review.")
            } else {
                List {
                    ForEach(vm.reviewingSections, id: \.group) { s in
                        Section(s.group.title) {
                            ForEach(s.prs) { r in
                                Button { selected = r.pr } label: { reviewingRow(r) }.buttonStyle(.plain)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func reviewingRow(_ r: ReviewingPR) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(verbatim: "\(r.pr.repository.nameWithOwner) #\(r.pr.number)")
                    .font(.caption).foregroundStyle(.secondary)
                if r.pr.isDraft {
                    Text("DRAFT").font(.caption2).padding(.horizontal, 4)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                ChecksIcon(state: r.checks)
            }
            Text(r.pr.title).font(.body).lineLimit(2)
            Text("\(r.pr.author.login) · \(r.status)")
                .font(.caption).foregroundStyle(r.group == .yours ? .blue : .secondary).lineLimit(2)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    // MARK: replies

    private var repliesList: some View {
        Group {
            if vm.visibleReplies.isEmpty && !vm.loading {
                empty("bubble.left.and.bubble.right", "No one is waiting on you in your review threads.")
            } else {
                List(vm.visibleReplies) { r in
                    Button { selected = r.pr } label: { replyRow(r) }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Dismiss until the next reply") { vm.dismissReplies(r) }
                        }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    // MARK: mentions

    private var mentionsList: some View {
        Group {
            if vm.visibleMentions.isEmpty && !vm.loading {
                empty("at", "No @mentions of you in the last week.")
            } else {
                List(vm.visibleMentions) { m in
                    Button { if let u = URL(string: m.url) { NSWorkspace.shared.open(u) } } label: { mentionRow(m) }
                        .buttonStyle(.plain)
                        .contextMenu { Button("Dismiss") { vm.dismissMention(m) } }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func mentionRow(_ m: Mention) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(verbatim: "\(m.repo) #\(m.number)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Dismiss") { vm.dismissMention(m) }.buttonStyle(.borderless).font(.caption)
            }
            Text(m.title).font(.body).lineLimit(2)
            Text("\(m.author) mentioned you \(age(m.updatedAt))").font(.caption).foregroundStyle(.blue)
            if !m.snippet.isEmpty {
                Text(m.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private func replyRow(_ r: ReplyPR) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(verbatim: "\(r.pr.repository.nameWithOwner) #\(r.pr.number)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Label("\(r.waiting)", systemImage: "bubble.left.fill")
                    .font(.caption).foregroundStyle(.blue)
            }
            Text(r.pr.title).font(.body).lineLimit(2)
            Text("\(r.latestBy) replied \(age(r.latestAt))")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    // MARK: my PRs

    private var mineList: some View {
        Group {
            if vm.visibleFeedback.isEmpty && !vm.loading {
                empty("tray", "No new feedback on your open PRs.")
            } else {
                List(vm.visibleFeedback) { f in
                    Button { selected = f.pr } label: { feedbackRow(f) }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Dismiss until new feedback") { vm.dismissFeedback(f) }
                        }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func feedbackRow(_ f: FeedbackPR) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(verbatim: "\(f.pr.repository.nameWithOwner) #\(f.pr.number)")
                    .font(.caption).foregroundStyle(.secondary)
                if f.pr.isDraft {
                    Text("DRAFT").font(.caption2).padding(.horizontal, 4)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                StatusBadge(feedback: f)
                DecisionBadge(decision: f.decision)
            }
            Text(f.pr.title).font(.body).lineLimit(2)
            Text("\(f.summary) · \(f.latestBy) \(age(f.latestAt))")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    // MARK: saved

    private var savedList: some View {
        VStack(spacing: 0) {
            if vm.saved.isEmpty {
                empty("tray", "No saved reviews yet.")
            } else {
                List(vm.saved) { s in
                    Button { selected = s.pr } label: { savedRow(s) }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Delete", role: .destructive) { vm.delete(s) }
                        }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            Divider()
            HStack {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Store.dir])
                }
                Spacer()
                Text("Right-click a row to delete").font(.caption2).foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }

    private func savedRow(_ s: SavedReview) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: "\(s.pr.repository.nameWithOwner) #\(s.pr.number)")
                .font(.caption).foregroundStyle(.secondary)
            Text(s.pr.title).lineLimit(2)
            Text("\(s.pr.author.login) · reviewed \(s.date.formatted(.relative(presentation: .named)))"
                 + (s.sinceCommit.map { " · changes since \($0)" } ?? "")
                 + (s.producedBy.map { " · \($0)" } ?? ""))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    // MARK: helpers

    private func title(_ t: Tab) -> String {
        switch t {
        case .pending where !vm.prs.isEmpty: return "\(t.rawValue) (\(vm.prs.count))"
        case .reviewing where vm.yourTurnCount > 0: return "\(t.rawValue) (\(vm.yourTurnCount))"
        case .replies where !vm.visibleReplies.isEmpty: return "\(t.rawValue) (\(vm.visibleReplies.count))"
        case .mine where !vm.visibleFeedback.isEmpty: return "\(t.rawValue) (\(vm.visibleFeedback.count))"
        case .mentions where !vm.visibleMentions.isEmpty: return "\(t.rawValue) (\(vm.visibleMentions.count))"
        default: return t.rawValue
        }
    }

    private func empty(_ icon: String, _ text: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.largeTitle)
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static let isoParser = ISO8601DateFormatter()
    private static let relative = RelativeDateTimeFormatter()

    /// Review requests open at least this long are flagged.
    static let oldAfterDays = 3

    private func daysSince(_ iso: String) -> Int {
        guard let d = Self.isoParser.date(from: iso) else { return 0 }
        return Calendar.current.dateComponents([.day], from: d, to: Date()).day ?? 0
    }

    private func age(_ iso: String) -> String {
        guard let d = Self.isoParser.date(from: iso) else { return "" }
        return Self.relative.localizedString(for: d, relativeTo: Date())
    }
}

struct DetailView: View {
    @EnvironmentObject var vm: ReviewViewModel
    @AppStorage(TerminalApp.key) private var terminalRaw = ""
    @AppStorage(ClaudeSettings.reviewCommandKey) private var reviewCommand = ClaudeSettings.reviewCommandDefault
    private var terminal: TerminalApp { TerminalApp.resolve(saved: terminalRaw, installed: TerminalApp.installed) }

    private func terminalLabel(_ verb: String) -> String { terminal.label(verb) }
    let pr: PR
    let back: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { back() } label: { Label("Back", systemImage: "chevron.left") }
                Spacer()
                Button("Open PR") { open(pr.url) }
                Button("Files") { open(pr.url + "/files") }
            }
            .buttonStyle(.borderless)

            Text(pr.title).font(.headline)
            Text(verbatim: "\(pr.repository.nameWithOwner) #\(pr.number) · \(pr.author.login)")
                .font(.caption).foregroundStyle(.secondary)

            if let f = vm.feedback(for: pr) {
                HStack {
                    DecisionBadge(decision: f.decision)
                    Text(f.threads + f.reviews + f.comments == 0
                         ? "\(f.summary)."
                         : "New feedback: \(f.summary). Latest from \(f.latestBy).")
                        .font(.caption).foregroundStyle(.blue)
                    Spacer()
                    Button("Dismiss") { vm.dismissFeedback(f) }
                        .buttonStyle(.borderless).font(.caption)
                }
            }

            if let r = vm.reply(for: pr) {
                HStack {
                    Text("\(r.waiting) of your review threads \(r.waiting == 1 ? "has a reply" : "have replies") waiting. "
                        + "Latest from \(r.latestBy).")
                        .font(.caption).foregroundStyle(.blue)
                    Spacer()
                    Button("Dismiss") { vm.dismissReplies(r) }
                        .buttonStyle(.borderless).font(.caption)
                }
            }

            if !vm.isMine(pr), case .idle = vm.state(for: pr), vm.hasOlderReview(pr) {
                if let earlier = vm.earlierReview(for: pr) {
                    Text("New commits since your review of \(earlier.pr.versionLabel). Review just those, "
                         + "checked against your earlier notes, or run a full review.")
                        .font(.caption).foregroundStyle(.orange)
                } else {
                    Text("This PR has new activity since your last review. The older one is under Saved.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            actions

            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !vm.isMine(pr), let r = vm.reviewingPR(for: pr), r.myLastReview != nil {
                        ReviewingDetailBox(reviewing: r)
                    }
                    if vm.canSummarise(pr) { summaryBox }
                    reviewContent
                }
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
    }

    /// Quick-model summary of the comments, or the button to make one.
    @ViewBuilder private var summaryBox: some View {
        let quick = Agent.current.label(Agent.current.quick)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Feedback summary").font(.caption.bold())
                Text(quick).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                switch vm.summaryState(for: pr) {
                case .running:
                    ProgressView().controlSize(.small)
                case .done:
                    Button("Redo") { vm.summarise(pr) }.buttonStyle(.borderless).font(.caption)
                default:
                    Button("Summarise feedback") { vm.summarise(pr) }.font(.caption)
                }
            }
            switch vm.summaryState(for: pr) {
            case .running:
                Text("Reading the comments…").foregroundStyle(.secondary)
            case .done(let text):
                MarkdownView(text: text)
                Text("Reads comments only, not code. Terminal gets this plus the full comments and diff.")
                    .font(.caption2).foregroundStyle(.secondary)
            case .failed(let msg):
                Text(msg).foregroundStyle(.red)
            case .idle:
                Text("A quick read of who said what and what's waiting on you. It doesn't see the code.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder private var reviewContent: some View {
        switch vm.state(for: pr) {
        case .done(let text):
            if let s = vm.savedReview(for: pr) {
                Text(ReviewPage.label(s)).font(.caption).foregroundStyle(.primary.opacity(0.75))
            }
            MarkdownView(text: text)
        case .failed(let msg):
            Text(msg).foregroundStyle(.red)
        default:
            Text(vm.isMine(pr)
                 ? "Opens \(Agent.current.appName) with the reviews, threads and comments on this PR plus the current diff. Nothing is ever posted to GitHub."
                 : "Private notes appear here and are saved locally. Nothing is ever posted to GitHub.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var actions: some View {
        HStack {
            if vm.isMine(pr) {
                Button(terminalLabel("Work through feedback")) { vm.openTerminal(pr) }
                    .buttonStyle(.borderedProminent)
            } else {
                reviewActions
            }
        }
        switch vm.draftState[pr.reviewKey] ?? .idle {
        case .done(let msg): Text(msg).font(.caption).foregroundStyle(.green)
        case .failed(let msg): Text(msg).font(.caption).foregroundStyle(.red)
        default: EmptyView()
        }
        if let notice = vm.terminalNotice {
            Text(notice).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewState private var confirmDraft = false

    /// "Draft on GitHub": asks first, since this is the one thing that writes to GitHub.
    @ViewBuilder private func draftButton(_ text: String) -> some View {
        let count = DraftReview.comments(from: text).count
        if case .running = vm.draftState[pr.reviewKey] ?? .idle {
            ProgressView().controlSize(.small)
        } else {
            Button("Draft on GitHub") { confirmDraft = true }
                .disabled(count == 0)
                .help(count == 0 ? "No non-nit findings with a file and line" : "Create a pending review from the findings, nits left out")
                .confirmationDialog("Create a draft review with \(count) comment\(count == 1 ? "" : "s")?",
                                    isPresented: $confirmDraft) {
                    Button("Create draft review") { vm.createDraft(pr) }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Nits are left out. The review stays pending, visible only to you, until you submit it on GitHub. You can edit or delete each comment there.")
                }
        }
    }

    @ViewBuilder private var reviewActions: some View {
        HStack {
            switch vm.state(for: pr) {
            case .running:
                ProgressView().controlSize(.small)
                Text("\(Agent.current.name) is reading the diff…").font(.caption)
                Button("Cancel") { vm.cancelReview(pr) }.font(.caption)
            case .done(let text):
                Button(terminalLabel("Follow up")) { vm.openTerminal(pr) }
                    .buttonStyle(.borderedProminent)
                Button("Open in browser") {
                    let s = vm.savedReview(for: pr)
                    ReviewPage.open(pr: pr, text: text, label: s.map(ReviewPage.label), date: s?.date)
                }
                draftButton(text)
                Button("Re-run") { vm.rerun(pr) }
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            default:
                if let earlier = vm.earlierReview(for: pr) {
                    Button("Review changes since \(earlier.pr.versionLabel)") { vm.reviewChanges(pr, since: earlier) }
                        .buttonStyle(.borderedProminent)
                    Button("Full review") { vm.review(pr) }
                    terminalButton
                } else if runsReviewCommand {
                    terminalButton.buttonStyle(.borderedProminent)
                    Button("Review with \(Agent.current.name)") { vm.review(pr) }
                        .help("Quick read-only review with the built-in prompt; notes are saved here")
                } else {
                    Button("Review with \(Agent.current.name)") { vm.review(pr) }
                        .buttonStyle(.borderedProminent)
                    terminalButton
                }
            }
        }
    }

    private var terminalButton: some View {
        Button(terminalLabel(vm.hasFollowUpContext(pr) ? "Follow up" : "Review")) { vm.openTerminal(pr) }
    }

    /// The terminal button sends your Review command (Settings › Terminal), so it becomes the main one.
    private var runsReviewCommand: Bool {
        !vm.hasFollowUpContext(pr) && Agent.current == .claude
            && ClaudeSettings.command(reviewCommand, url: pr.url) != nil
    }

    private func open(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }
}

struct SettingsView: View {
    @ViewState private var repos = RepoList.load()
    @ViewState private var legacyOwner = UserDefaults.standard.string(forKey: RepoList.legacyOwnerKey) ?? ""
    @ViewState private var input = ""
    @ViewState private var checking = false
    @ViewState private var problems: [String] = []
    @ViewState private var folders: [String: String] = [:]
    @AppStorage(ClaudeSettings.reviewModelKey) private var reviewModel = ClaudeSettings.reviewModelDefault
    @AppStorage(ClaudeSettings.reviewEffortKey) private var reviewEffort = ClaudeSettings.reviewEffortDefault
    @AppStorage(ClaudeSettings.quickModelKey) private var quickModel = ClaudeSettings.quickModelDefault
    @AppStorage(ClaudeSettings.quickEffortKey) private var quickEffort = ClaudeSettings.quickEffortDefault
    @AppStorage(Agent.key) private var agentRaw = Agent.claude.rawValue
    @AppStorage(CodexSettings.reviewModelKey) private var codexReviewModel = ""
    @AppStorage(CodexSettings.reviewEffortKey) private var codexReviewEffort = ""
    @AppStorage(CodexSettings.quickModelKey) private var codexQuickModel = ""
    @AppStorage(CodexSettings.quickEffortKey) private var codexQuickEffort = CodexSettings.quickEffortDefault
    @AppStorage(PRFilter.includeDraftsKey) private var includeDrafts = true
    @AppStorage(AutoReview.key) private var autoReview = false
    @AppStorage(StayOpen.key) private var stayOpen = false
    @AppStorage(AsWindow.key) private var asWindow = false
    @AppStorage(TerminalApp.key) private var terminalRaw = ""
    @AppStorage(ClaudeSettings.reviewCommandKey) private var reviewCommand = ClaudeSettings.reviewCommandDefault
    @AppStorage(ClaudeSettings.verifyCommandKey) private var verifyCommand = ClaudeSettings.verifyCommandDefault
    @AppStorage(TerminalApp.Worktree.nextToCloneKey) private var worktreesNextToClone = false
    @AppStorage(NotifySettings.requestsKey) private var notifyRequests = true
    @AppStorage(NotifySettings.repliesKey) private var notifyReplies = true
    @AppStorage(NotifySettings.feedbackKey) private var notifyFeedback = true
    @AppStorage(NotifySettings.pushedKey) private var notifyPushed = true
    @AppStorage(NotifySettings.resolvedKey) private var notifyAllResolved = true
    @AppStorage(NotifySettings.verdictsKey) private var notifyVerdicts = true
    @AppStorage(NotifySettings.mentionsKey) private var notifyMentions = true
    @ViewState private var notificationsAllowed: UNAuthorizationStatus?
    @ViewState private var openAtLogin = LoginItem.isAvailable && LoginItem.status == .enabled
    @ViewState private var loginProblem: String?
    let done: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView { form.padding(10) }
            Divider()
            HStack {
                Spacer()
                Button("Done", action: done).buttonStyle(.borderedProminent)
            }
            .padding(10)
        }
        .task { notificationsAllowed = await Notifier.authorizationStatus() }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Repositories").font(.headline)
            Text("PRs from these repos show up in every tab. Mix any orgs and users.")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                TextField("owner/repo or GitHub URL", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || checking)
            }
            Text("Paste several at once, separated by spaces, commas or new lines.")
                .font(.caption2).foregroundStyle(.secondary)

            if checking {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Checking access…").font(.caption)
                }
            }
            ForEach(problems, id: \.self) { p in
                Text(p).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }

            if repos.isEmpty && !legacyOwner.isEmpty {
                HStack {
                    Text("Watching everything in \(legacyOwner) (from older settings). Add repos to narrow it down.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Stop") {
                        UserDefaults.standard.removeObject(forKey: RepoList.legacyOwnerKey)
                        legacyOwner = ""
                    }
                    .buttonStyle(.borderless).font(.caption)
                }
            }

            List {
                ForEach(repos, id: \.self) { r in
                    HStack {
                        Image(systemName: "book.closed").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r).font(.system(.body, design: .monospaced))
                            if let f = folders[r.lowercased()] {
                                Text((f as NSString).abbreviatingWithTildeInPath)
                                    .font(.caption2).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            } else if let f = RepoList.detectFolder(for: r) {
                                Text("Found \((f as NSString).abbreviatingWithTildeInPath)")
                                    .font(.caption2).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            } else {
                                Text("No local clone found: choose one to open Terminal there")
                                    .font(.caption2).foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                        Button { chooseFolder(for: r) } label: {
                            Image(systemName: folders[r.lowercased()] == nil ? "folder.badge.plus" : "folder")
                        }
                        .buttonStyle(.borderless)
                        .help(folders[r.lowercased()] == nil
                              ? "Choose the local checkout of \(r): Terminal sessions start there"
                              : "Change the local folder (Terminal sessions start there)")
                        .contextMenu {
                            if folders[r.lowercased()] != nil {
                                Button("Forget folder") { RepoList.setFolder(nil, for: r); loadFolders() }
                            }
                        }
                        Button { remove(r) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Remove \(r)")
                            .accessibilityLabel("Remove \(r)")
                    }
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(height: 150)
            .onAppear(perform: loadFolders)
            .overlay {
                if repos.isEmpty {
                    Text("No repos yet").font(.callout).foregroundStyle(.secondary)
                }
            }

            Text("\(repos.count) repo\(repos.count == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.secondary)

            Divider()
            Text("AI tool").font(.headline)
            Picker("AI tool", selection: $agentRaw) {
                ForEach(Agent.allCases) { a in Text(a.appName).tag(a.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            if agentRaw == Agent.codex.rawValue {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    Text("Model").font(.caption).foregroundStyle(.secondary)
                    Text("Effort").font(.caption).foregroundStyle(.secondary)
                }
                GridRow {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Reviews & terminal")
                        Text("Reads the code").font(.caption2).foregroundStyle(.secondary)
                    }
                    modelField($codexReviewModel, placeholder: "Default")
                    picker($codexReviewEffort, CodexSettings.efforts, "Review effort")
                }
                GridRow {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Feedback summaries")
                        Text("Reads comments only").font(.caption2).foregroundStyle(.secondary)
                    }
                    modelField($codexQuickModel, placeholder: "Same as reviews")
                    picker($codexQuickEffort, CodexSettings.efforts, "Summary effort")
                }
            }
            Text("Type a model name such as gpt-5.5, or leave empty for your Codex config. "
                 + "Uses your ChatGPT login, never an API key. Reviews run in a read-only sandbox.")
                .font(.caption2).foregroundStyle(.secondary)
            } else {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    Text("Model").font(.caption).foregroundStyle(.secondary)
                    Text("Effort").font(.caption).foregroundStyle(.secondary)
                }
                GridRow {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Reviews & terminal")
                        Text("Reads the code").font(.caption2).foregroundStyle(.secondary)
                    }
                    picker($reviewModel, ClaudeSettings.models, "Review model")
                    picker($reviewEffort, ClaudeSettings.efforts, "Review effort")
                }
                GridRow {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Feedback summaries")
                        Text("Reads comments only").font(.caption2).foregroundStyle(.secondary)
                    }
                    picker($quickModel, ClaudeSettings.quickModels, "Summary model")
                    picker($quickEffort, ClaudeSettings.efforts, "Summary effort")
                }
            }
            Text("Models follow the latest release in each family. Default uses your Claude Code settings. "
                 + "Code is always read by the review model; "
                 + "summaries are handed to it as a starting point.")
                .font(.caption2).foregroundStyle(.secondary)

            }

            Divider()
            Text("Terminal").font(.headline)
            let installed = TerminalApp.installed
            let resolved = TerminalApp.resolve(saved: terminalRaw, installed: installed)
            let automatic = TerminalApp.resolve(saved: "", installed: installed)
            HStack {
                Text("Open \(Agent(rawValue: agentRaw)?.appName ?? "Claude Code") in")
                Picker("Terminal app", selection: $terminalRaw) {
                    Text("Automatic (\(automatic.name))").tag("")
                    Divider()
                    ForEach(installed) { app in Text(app.name).tag(app.rawValue) }
                    // A saved choice that is no longer installed stays visible, so it can be changed.
                    if let saved = TerminalApp(rawValue: terminalRaw), !installed.contains(saved) {
                        Text("\(saved.name) (not installed)").tag(saved.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 200)
            }
            Group {
                if let saved = TerminalApp(rawValue: terminalRaw), !installed.contains(saved) {
                    Text("\(saved.name) isn't installed here, so \(resolved.name) is used.")
                        .foregroundStyle(.orange)
                } else {
                    switch resolved {
                    case .terminal, .iterm:
                        Text("macOS asks once for permission to control \(resolved.name).")
                    case .ghostty, .kitty, .alacritty:
                        Text("Each session opens in a new \(resolved.name) window.")
                    case .wezterm:
                        Text("Each session opens in a new WezTerm window.")
                    case .copy:
                        Text("For Warp or any other terminal: the button copies a command to paste.")
                    }
                }
            }
            .font(.caption2).foregroundStyle(.secondary)
            HStack {
                Text("Review command")
                TextField("Review command", text: $reviewCommand, prompt: Text("Built-in review prompt"))
                    .labelsHidden()
                    .disabled(agentRaw == Agent.codex.rawValue)
            }
            Text(agentRaw == Agent.codex.rawValue
                 ? "Claude Code only. Codex reviews use the built-in prompt."
                 : "The first message of a new review in the terminal, with {url} as the PR's link. "
                   + "Leave it empty for the built-in review prompt.")
                .font(.caption2).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline) {
                Text("Verify command")
                TextField("Verify command", text: $verifyCommand, prompt: Text("No Verify fixes button"),
                          axis: .vertical)
                    .lineLimit(1...4)
                    .labelsHidden()
                    .disabled(agentRaw == Agent.codex.rawValue)
            }
            Text(agentRaw == Agent.codex.rawValue
                 ? "Claude Code only."
                 : "Sent by Verify fixes (PRs where you have review threads), with {url} as the PR's link. "
                   + "Leave it empty to hide the button.")
                .font(.caption2).foregroundStyle(.secondary)
            Toggle("Put PR worktrees next to the clone", isOn: $worktreesNextToClone)
            Text(worktreesNextToClone
                 ? "Each PR is checked out in <clone>-worktrees/pr-<number>, e.g. gauss-worktrees/pr-42."
                 : "Each PR is checked out in ReviewBar's Application Support folder.")
                .font(.caption2).foregroundStyle(.secondary)

            Divider()
            Text("Pull requests").font(.headline)
            Toggle("Include draft PRs", isOn: $includeDrafts)
            Text("Applies to Awaiting me, Reviewing and Replies. Your own drafts always show in My PRs.")
                .font(.caption2).foregroundStyle(.secondary)
            Toggle("Review new requests automatically", isOn: $autoReview)
            Text("Runs a full review in the background when a PR first asks for your review, one at a time, "
                 + "and notifies you when it's ready. Uses your \(Agent(rawValue: agentRaw)?.name ?? "Claude") plan; "
                 + "PRs already waiting are left alone.")
                .font(.caption2).foregroundStyle(.secondary)

            Divider()
            Text("Notifications").font(.headline)
            Toggle("New review requests and re-requests", isOn: $notifyRequests)
            Toggle("Replies on your review threads", isOn: $notifyReplies)
            Toggle("New commits after your review", isOn: $notifyPushed)
            Toggle("All your threads on a PR resolved", isOn: $notifyAllResolved)
            Toggle("Other reviewers approve or request changes", isOn: $notifyVerdicts)
            Toggle("Feedback on your PRs", isOn: $notifyFeedback)
            Toggle("@mentions of you or your teams", isOn: $notifyMentions)
            notificationHint

            Divider()
            Text("Panel").font(.headline)
            Toggle("Open as a window", isOn: $asWindow)
            Text("A normal window you can move and resize, open until you close it. Takes effect the next time you click the menu bar icon.")
                .font(.caption2).foregroundStyle(.secondary)
            Toggle("Stay open when clicking elsewhere", isOn: $stayOpen)
                .disabled(asWindow)
            Text("Close it with the menu bar icon or Esc.")
                .font(.caption2).foregroundStyle(.secondary)

            Divider()
            Text("Startup").font(.headline)
            Toggle("Open at login", isOn: $openAtLogin)
                .disabled(!LoginItem.isAvailable)
                .onChange(of: openAtLogin) { _, on in setOpenAtLogin(on) }
            if !LoginItem.isAvailable {
                Text("Needs the app bundle: build it with scripts/make-app.sh and run it from /Applications.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if LoginItem.status == .requiresApproval {
                Text("Approve ReviewBar in System Settings › General › Login Items.")
                    .font(.caption2).foregroundStyle(.orange)
            }
            if let loginProblem {
                Text(loginProblem).font(.caption2).foregroundStyle(.red)
            }
        }
        .toggleStyle(.checkbox)
    }

    @ViewBuilder private var notificationHint: some View {
        if !Notifier.isAvailable {
            Text("Notifications need the app bundle: build it with scripts/make-app.sh.")
                .font(.caption2).foregroundStyle(.secondary)
        } else if notificationsAllowed == .denied {
            HStack {
                Text("Notifications are turned off for ReviewBar in System Settings.")
                    .font(.caption2).foregroundStyle(.orange)
                Button("Open Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.borderless).font(.caption2)
            }
        } else {
            Text("Clicking a notification opens the PR on GitHub. Several at once are grouped into one.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func setOpenAtLogin(_ on: Bool) {
        let current = LoginItem.status == .enabled
        guard on != current else { return }
        do {
            try LoginItem.set(on)
            loginProblem = nil
        } catch {
            loginProblem = "Couldn't change the login item: \(error.localizedDescription)"
            openAtLogin = LoginItem.status == .enabled
        }
    }

    /// Normalises each pasted entry, checks `gh` can read it, then appends the canonical name.
    private func add() {
        let entries = input
            .split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .map(String.init)
        guard !entries.isEmpty, !checking else { return }
        problems = []
        checking = true
        Task {
            var added: [String] = []
            var failed: [String] = []
            for raw in entries {
                guard let name = RepoList.normalize(raw) else {
                    problems.append("“\(raw)” isn't owner/repo.")
                    failed.append(raw)
                    continue
                }
                if (repos + added).contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { continue }
                do {
                    added.append(try await Backend.checkRepo(name))
                } catch {
                    problems.append(error.localizedDescription)
                    failed.append(raw)
                }
            }
            repos += added
            RepoList.save(repos)
            input = failed.joined(separator: " ")   // keep what didn't work, so it can be fixed
            checking = false
        }
    }

    private func modelField(_ value: Binding<String>, placeholder: String) -> some View {
        TextField(placeholder, text: value)
            .textFieldStyle(.roundedBorder)
            .frame(width: 120)
            .foregroundStyle(CodexSettings.isValidModel(value.wrappedValue) ? Color.primary : Color.red)
            .help("Letters, digits, dots, dashes and underscores only")
    }

    private func picker(_ value: Binding<String>, _ options: [String], _ label: String) -> some View {
        Picker(label, selection: value) {
            ForEach(options, id: \.self) { Text(ClaudeSettings.displayName($0)).tag($0) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 120)
        .accessibilityLabel(label)
    }

    private func remove(_ r: String) {
        repos.removeAll { $0 == r }
        RepoList.save(repos)
        RepoList.setFolder(nil, for: r)
        loadFolders()
    }

    private func loadFolders() {
        folders = Dictionary(uniqueKeysWithValues: repos.compactMap { r in
            RepoList.chosenFolder(for: r).map { (r.lowercased(), $0) }
        })
    }

    /// Picks the repo's local checkout. Warns (but still saves) if its git remotes point elsewhere.
    private func chooseFolder(for repo: String) {
        let open = NSOpenPanel()
        open.canChooseDirectories = true
        open.canChooseFiles = false
        open.allowsMultipleSelection = false
        open.prompt = "Use Folder"
        open.message = "Choose your local clone of \(repo). Terminal sessions for its PRs start there."
        if let f = RepoList.folder(for: repo) { open.directoryURL = URL(fileURLWithPath: f) }
        MenuBarController.keepOpen = true
        open.level = .popUpMenu + 1
        NSApp.activate(ignoringOtherApps: true)
        open.begin { response in
            MenuBarController.keepOpen = false
            guard response == .OK, let url = open.url else { return }
            saveFolder(url, for: repo)
        }
    }

    private func saveFolder(_ url: URL, for repo: String) {
        RepoList.setFolder(url.path, for: repo)
        loadFolders()
        Task {
            let remotes = (try? await sh("git -C \(q(url.path)) remote -v")) ?? ""
            if !RepoList.remotesMatch(remotes, repo: repo) {
                problems = ["\((url.path as NSString).abbreviatingWithTildeInPath) has no git remote for \(repo). "
                            + "Saved anyway; check it's the right folder."]
            }
        }
    }
}

/// GitHub's overall review decision on a PR, as a small coloured label.
struct DecisionBadge: View {
    let decision: String?

    var body: some View {
        switch decision ?? "" {
        case "APPROVED":
            Label("Approved", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case "CHANGES_REQUESTED":
            Label("Changes requested", systemImage: "exclamationmark.circle.fill")
                .font(.caption).foregroundStyle(.orange)
        default:
            EmptyView()
        }
    }
}

/// CI state of a PR's head commit as a small icon; nothing when it has no checks.
struct ChecksIcon: View {
    let state: String?

    var body: some View {
        switch state ?? "" {
        case "SUCCESS":
            Image(systemName: "checkmark.circle").foregroundStyle(.green).help("Checks passed")
        case "FAILURE", "ERROR":
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).help("Checks failing")
        case "PENDING", "EXPECTED":
            Image(systemName: "clock").foregroundStyle(.secondary).help("Checks running")
        default:
            EmptyView()
        }
    }
}

/// CI and merge state of one of your PRs: conflict, failing checks, running, or ready to merge.
struct StatusBadge: View {
    let feedback: FeedbackPR

    var body: some View {
        if let status = feedback.status {
            Label(status, systemImage: icon)
                .font(.caption)
                .foregroundStyle(color)
        }
    }

    private var icon: String {
        if feedback.hasConflict { return "arrow.triangle.merge" }
        if feedback.checksFailing { return "xmark.octagon.fill" }
        if feedback.readyToMerge { return "checkmark.seal.fill" }
        return "clock"
    }

    private var color: Color {
        if feedback.hasConflict || feedback.checksFailing { return .red }
        if feedback.readyToMerge { return .green }
        return .secondary
    }
}

