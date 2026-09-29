import SwiftUI
import AppKit
import ServiceManagement
import UserNotifications

private enum Tab: String, CaseIterable {
    case pending = "Awaiting me"
    case replies = "Replies"
    case mine = "My PRs"
    case saved = "Saved"
}

struct ContentView: View {
    @EnvironmentObject var vm: ReviewViewModel
    @State private var showSettings = false
    @State private var selected: PR?
    @State private var tab: Tab = .pending

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if showSettings {
                SettingsView {
                    showSettings = false
                    Task { await vm.refresh() }
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
                case .replies: repliesList
                case .mine: mineList
                case .saved: savedList
                }
            }
        }
        .frame(width: 480, height: 580)
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
                List(vm.prs) { pr in
                    Button { selected = pr } label: { row(pr) }.buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
    }

    private func row(_ pr: PR) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("\(pr.repository.nameWithOwner) #\(pr.number)")
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
            Text("\(pr.author.login) · updated \(age(pr.updatedAt))")
                .font(.caption).foregroundStyle(.secondary)
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
            }
        }
    }

    private func replyRow(_ r: ReplyPR) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("\(r.pr.repository.nameWithOwner) #\(r.pr.number)")
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
            }
        }
    }

    private func feedbackRow(_ f: FeedbackPR) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("\(f.pr.repository.nameWithOwner) #\(f.pr.number)")
                    .font(.caption).foregroundStyle(.secondary)
                if f.pr.isDraft {
                    Text("DRAFT").font(.caption2).padding(.horizontal, 4)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
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
            Text("\(s.pr.repository.nameWithOwner) #\(s.pr.number)")
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
        case .replies where !vm.visibleReplies.isEmpty: return "\(t.rawValue) (\(vm.visibleReplies.count))"
        case .mine where !vm.visibleFeedback.isEmpty: return "\(t.rawValue) (\(vm.visibleFeedback.count))"
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

    private func age(_ iso: String) -> String {
        guard let d = Self.isoParser.date(from: iso) else { return "" }
        return Self.relative.localizedString(for: d, relativeTo: Date())
    }
}

struct DetailView: View {
    @EnvironmentObject var vm: ReviewViewModel
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
            Text("\(pr.repository.nameWithOwner) #\(pr.number) · \(pr.author.login)")
                .font(.caption).foregroundStyle(.secondary)

            if let f = vm.feedback(for: pr) {
                HStack {
                    DecisionBadge(decision: f.decision)
                    Text("New feedback: \(f.summary). Latest from \(f.latestBy).")
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
                    if vm.canSummarise(pr) { summaryBox }
                    reviewContent
                }
                .font(.system(size: 12))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
    }

    /// Quick-model summary of the comments, or the button to make one.
    @ViewBuilder private var summaryBox: some View {
        let quick = ClaudeSettings.label(ClaudeSettings.quick)
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
                Text(rendered(text))
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
                Text(reviewLabel(s)).font(.caption2).foregroundStyle(.secondary)
            }
            Text(rendered(text))
        case .failed(let msg):
            Text(msg).foregroundStyle(.red)
        default:
            Text(vm.isMine(pr)
                 ? "Opens Claude Code with the reviews, threads and comments on this PR plus the current diff. Nothing is ever posted to GitHub."
                 : "Private notes appear here and are saved locally. Nothing is ever posted to GitHub.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var actions: some View {
        HStack {
            if vm.isMine(pr) {
                Button("Work through feedback in Terminal") { vm.openTerminal(pr) }
                    .buttonStyle(.borderedProminent)
            } else {
                reviewActions
            }
        }
    }

    @ViewBuilder private var reviewActions: some View {
        HStack {
            switch vm.state(for: pr) {
            case .running:
                ProgressView().controlSize(.small)
                Text("Claude is reading the diff…").font(.caption)
            case .done(let text):
                Button("Follow up in Terminal") { vm.openTerminal(pr) }
                    .buttonStyle(.borderedProminent)
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
                } else {
                    Button("Review with Claude") { vm.review(pr) }
                        .buttonStyle(.borderedProminent)
                }
                Button(vm.hasFollowUpContext(pr) ? "Follow up in Terminal" : "Review in Terminal") {
                    vm.openTerminal(pr)
                }
            }
        }
    }

    /// "Review · Opus", "Changes since abc1234 · Opus", or the rebased fallback.
    private func reviewLabel(_ s: SavedReview) -> String {
        var parts: [String] = []
        if let since = s.sinceCommit {
            parts.append(s.sinceFellBack == true ? "Since \(since), full diff (branch rebased)" : "Changes since \(since)")
        } else {
            parts.append("Review")
        }
        if let by = s.producedBy { parts.append(by) }
        return parts.joined(separator: " · ")
    }

    private func rendered(_ s: String) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: s, options: opts)) ?? AttributedString(s)
    }

    private func open(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }
}

struct SettingsView: View {
    @State private var repos = RepoList.load()
    @State private var legacyOwner = UserDefaults.standard.string(forKey: RepoList.legacyOwnerKey) ?? ""
    @State private var input = ""
    @State private var checking = false
    @State private var problems: [String] = []
    @AppStorage(ClaudeSettings.reviewModelKey) private var reviewModel = ClaudeSettings.reviewModelDefault
    @AppStorage(ClaudeSettings.reviewEffortKey) private var reviewEffort = ClaudeSettings.reviewEffortDefault
    @AppStorage(ClaudeSettings.quickModelKey) private var quickModel = ClaudeSettings.quickModelDefault
    @AppStorage(ClaudeSettings.quickEffortKey) private var quickEffort = ClaudeSettings.quickEffortDefault
    @AppStorage(NotifySettings.requestsKey) private var notifyRequests = true
    @AppStorage(NotifySettings.repliesKey) private var notifyReplies = true
    @AppStorage(NotifySettings.feedbackKey) private var notifyFeedback = true
    @State private var notificationsAllowed: UNAuthorizationStatus?
    @State private var openAtLogin = LoginItem.isAvailable && LoginItem.status == .enabled
    @State private var loginProblem: String?
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
        .onAppear { Notifier.authorizationStatus { notificationsAllowed = $0 } }
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
                        Text(r).font(.system(.body, design: .monospaced))
                        Spacer()
                        Button { remove(r) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Remove \(r)")
                            .accessibilityLabel("Remove \(r)")
                    }
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(height: 130)
            .overlay {
                if repos.isEmpty {
                    Text("No repos yet").font(.callout).foregroundStyle(.secondary)
                }
            }

            Text("\(repos.count) repo\(repos.count == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.secondary)

            Divider()
            Text("Claude").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    Text("Model").font(.caption).foregroundStyle(.secondary)
                    Text("Effort").font(.caption).foregroundStyle(.secondary)
                }
                GridRow {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Reviews & Terminal")
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

            Divider()
            Text("Notifications").font(.headline)
            Toggle("New review requests", isOn: $notifyRequests)
            Toggle("Replies on your review threads", isOn: $notifyReplies)
            Toggle("Feedback on your PRs", isOn: $notifyFeedback)
            notificationHint

            Divider()
            Text("Startup").font(.headline)
            Toggle("Open at login", isOn: $openAtLogin)
                .disabled(!LoginItem.isAvailable)
                .onChange(of: openAtLogin) { on in setOpenAtLogin(on) }
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
