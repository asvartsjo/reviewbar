import SwiftUI
import AppKit
import ServiceManagement
import UserNotifications

private enum Tab: String, CaseIterable {
    case crew = "Crew"
    case reviewing = "Reviewing"
    case mine = "My PRs"
    case mentions = "Mentions"
}

struct ContentView: View {
    @ViewState private var systemDark = ContentView.isSystemDark
    static var isSystemDark: Bool { UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" }
    @EnvironmentObject var vm: ReviewViewModel
    @ViewState private var showSettings = false
    @ViewState private var selected: PR?
    @ViewState private var tab: Tab = .reviewing
    @ViewState private var showMuted = false
    @ViewState private var showParked = false
    @ViewState private var showIdleCrew = false
    @AppStorage(TerminalApp.key) private var terminalRaw = ""
    private var terminal: TerminalApp { TerminalApp.resolve(saved: terminalRaw, installed: TerminalApp.installed) }
    @AppStorage(AsWindow.key) private var asWindow = false

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

                if let e = vm.error {
                    Text(e).font(.caption).foregroundStyle(.red).padding(.horizontal, 10)
                }
                switch tab {
                case .reviewing: reviewingList
                case .mine: mineList
                case .mentions: mentionsList
                case .crew: crewList
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
            // The window's title bar already says ReviewBar; the popup has none.
            if !asWindow { Text("Reviews").font(.headline) }
            Spacer()
            if vm.loading { ProgressView().controlSize(.small) }
            Button { Task { await vm.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh now").accessibilityLabel("Refresh")
            Button { showSettings.toggle() } label: { Image(systemName: "gearshape") }
                .help(showSettings ? "Close Settings" : "Settings").accessibilityLabel("Settings")
            Button { NSApplication.shared.terminate(nil) } label: { Image(systemName: "power") }
                .help("Quit ReviewBar").accessibilityLabel("Quit ReviewBar")
        }
        .buttonStyle(.hoverBorderless)
        .padding(10)
    }

    // MARK: reviewing

    @ViewBuilder private var reviewAllBar: some View {
        HStack {
            if let b = vm.batch {
                ProgressView(value: Double(b.done), total: Double(b.total)).frame(width: 120)
                Text("Reviewed \(b.done) of \(b.total)").font(.caption)
                Spacer()
                Button("Stop", systemImage: "stop.circle") { vm.cancelAll() }.font(.caption)
                    .help("Stop the remaining reviews")
            } else if !vm.unreviewed.isEmpty {
                Text("\(vm.unreviewed.count) without a review").font(.caption)
                Spacer()
                Menu("Review all", systemImage: "sparkles") {
                    Button("One by one") { vm.reviewAll(parallel: false) }
                    Button("In parallel (3 at a time)") { vm.reviewAll(parallel: true) }
                }
                .menuStyle(.borderlessButton).fixedSize().font(.caption)
                .help("Review every PR you haven't reviewed yet with \(Agent.current.name). Notes stay in ReviewBar.")
                .modifier(HoverHighlight(inset: 4))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
    }

    /// ✨ when a review made here is saved for this version, 🕘 when only an older one is.
    @ViewBuilder private func savedReviewIcon(_ pr: PR) -> some View {
        if case .done = vm.state(for: pr) {
            Image(systemName: "sparkles").foregroundStyle(.orange).help("Review saved in ReviewBar")
        } else if vm.hasOlderReview(pr) {
            Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                .help("A review of an older version is saved in ReviewBar")
        }
    }

    /// "open 4d", orange from `oldAfterDays`.
    @ViewBuilder private func openAge(_ pr: PR) -> some View {
        if let opened = pr.createdAt {
            let days = daysSince(opened)
            Text(days < 1 ? "open today" : "open \(days)d")
                .foregroundStyle(days >= Self.oldAfterDays ? .orange : .secondary)
                .help(days < 1 ? "Opened today" : "Open for \(days) day\(days == 1 ? "" : "s")")
        }
    }

    private var reviewingList: some View {
        Group {
            if vm.reviewing.isEmpty && !vm.loading {
                empty("eyeglasses", "No open PRs you review.")
            } else {
                reviewAllBar
                List {
                    ForEach(vm.reviewingSections, id: \.group) { s in
                        Group {
                            if s.group == .muted {
                                Button { showMuted.toggle() } label: {
                                    sectionHeader(s.group.title, count: s.prs.count, folded: !showMuted)
                                }
                                .buttonStyle(.hoverRow)
                                .help(showMuted ? "Hide muted PRs" : "Show muted PRs")
                            } else {
                                sectionHeader(s.group.title, count: s.prs.count)
                            }
                        }
                        .padding(.top, s.group == vm.reviewingSections.first?.group ? 0 : 10)
                        .listRowSeparator(.hidden)
                        ForEach(s.group == .muted && !showMuted ? [] : s.prs) { r in
                            Button { selected = r.pr } label: { reviewingRow(r) }
                                .listRowSeparator(.hidden)
                                .buttonStyle(.hoverRow)
                                .opacity(s.group == .muted ? 0.55 : 1)
                                .contextMenu {
                                    if vm.isMuted(r) {
                                        Button("Unmute", systemImage: "bell") { vm.unmute(r) }
                                    } else if !r.isRequested {
                                        Button("Mute until something happens", systemImage: "bell.slash") { vm.muteUntilSomethingHappens(r) }
                                        Button("Mute for good", systemImage: "bell.slash.fill") { vm.muteForGood(r) }
                                    } else if r.myLastReview == nil {   // a re-request always shows
                                        Button("Mute for good", systemImage: "bell.slash.fill") { vm.muteForGood(r) }
                                    }
                                }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    /// "YOUR TURN 6": capitals in the primary colour over a line, so the groups stand out from
    /// the rows, which have no separators. A plain row, not a Section header: a pinned header
    /// gets a second line from macOS. `folded` adds a chevron (Muted starts folded).
    private func sectionHeader(_ title: String, count: Int, folded: Bool? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).textCase(.uppercase).font(.callout.bold()).tracking(0.6).foregroundStyle(.primary)
                Text(verbatim: "\(count)").font(.callout).foregroundStyle(.secondary)
                if let folded {
                    Image(systemName: folded ? "chevron.right" : "chevron.down")
                        .font(.caption.bold()).foregroundStyle(.secondary)
                }
            }
            Divider()
        }
    }

    /// The dot sits in its own column, so titles line up whether or not a row is new.
    private func reviewingRow(_ r: ReviewingPR) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Group {
                if vm.isNew(r) { NewDot() } else { Color.clear.frame(width: 7, height: 7) }
            }
            .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    numberedTitle(r.pr.number, r.pr.title)
                    if r.pr.isDraft { draftBadge }
                    Spacer(minLength: 4)
                    HStack(spacing: 5) {
                        if let item = vm.crewItem(for: r.pr) { CrewBadge(item: item) }
                        if r.isRequested { openAge(r.pr) }
                        savedReviewIcon(r.pr)
                        ChecksIcon(state: r.checks, labelled: true)
                    }
                    .font(.caption)
                }
                metaLine(r.pr.repository.nameWithOwner, r.pr.author.login, " · \(r.status)")
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    // MARK: mentions

    private var mentionsList: some View {
        Group {
            if vm.visibleMentions.isEmpty && !vm.loading {
                empty("at", "No @mentions of you in the last week.")
            } else {
                List(vm.visibleMentions) { m in
                    Button { if let u = URL(string: m.url) { NSWorkspace.shared.open(u) } } label: { mentionRow(m) }
                        .listRowSeparator(.hidden)
                        .buttonStyle(.hoverRow)
                        .contextMenu { Button("Dismiss", systemImage: "xmark") { vm.dismissMention(m) } }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func mentionRow(_ m: Mention) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                numberedTitle(m.number, m.title)
                Spacer(minLength: 4)
                Button("Dismiss", systemImage: "xmark") { vm.dismissMention(m) }.buttonStyle(.hoverBorderless).font(.caption)
                    .help("Hide this mention until it gets a new comment")
            }
            metaLine(m.repo, m.author, " mentioned you \(age(m.updatedAt))")
            if !m.snippet.isEmpty {
                Text(m.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: my PRs

    /// Your open PRs by whose move it is, Parked folded.
    private var mineList: some View {
        Group {
            if vm.myPRs.isEmpty && !vm.loading {
                empty("tray", "No open PRs of yours.")
            } else {
                let sections = vm.mySections
                List {
                    moveSummary(sections)
                        .listRowSeparator(.hidden)
                    ForEach(sections, id: \.group) { s in
                        Group {
                            if s.group == .parked {
                                Button { showParked.toggle() } label: {
                                    sectionHeader(s.group.title, count: s.prs.count, folded: !showParked)
                                }
                                .buttonStyle(.hoverRow)
                                .help("\(showParked ? "Hide" : "Show") PRs you parked, and drafts with no commit for \(MyGroup.oldDraftDays)+ days")
                            } else {
                                sectionHeader(s.group.title, count: s.prs.count)
                            }
                        }
                        .padding(.top, 6)
                        .listRowSeparator(.hidden)
                        ForEach(s.group == .parked && !showParked ? [] : s.prs) { f in
                            let new = vm.visibleFeedback.contains(f)
                            Button { selected = f.pr } label: { feedbackRow(f, quiet: !new, hint: s.group != .parked) }
                                .listRowSeparator(.hidden)
                                .buttonStyle(.hoverRow)
                                .opacity(s.group == .parked ? 0.55 : 1)
                                .contextMenu {
                                    if new {
                                        Button("Dismiss until new feedback", systemImage: "xmark") { vm.dismissFeedback(f) }
                                    }
                                    if let action = vm.myPRAction(for: f.pr) {
                                        Button(terminal.label(action.title), systemImage: TerminalApp.symbol) { vm.runMyPRAction(f.pr) }
                                    }
                                    if vm.isParked(f) {
                                        Button("Unpark", systemImage: "tray.and.arrow.up") { vm.unpark(f) }
                                    } else if s.group != .parked {
                                        Button("Park", systemImage: "tray.and.arrow.down") { vm.park(f) }
                                    }
                                }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    /// A Claude session in one of your repos. A background one opens with `claude attach`; a terminal
    /// one opens its PR if known, else brings its tab to the front. Right-click: Show and Stop.
    @ViewBuilder private func crewRow(_ item: CrewItem) -> some View {
        let pr = vm.pr(for: item)
        let row = VStack(alignment: .leading, spacing: 2) {
            if let pr { numberedTitle(pr.number, pr.title) } else {
                Text(verbatim: item.session.displayName).font(.body.weight(.medium)).lineLimit(1)
            }
            (Text(verbatim: "\(pr == nil && item.session.title == nil ? item.repo : item.session.name) · ").foregroundStyle(.secondary)
                + Text(item.session.needsMe ? "needs you" : item.session.working ? "working" : "idle")
                    .foregroundStyle(item.session.needsMe ? Color.orange : Color.secondary)
                + Text(verbatim: " · \(item.session.background ? "agent view" : item.session.host?.name ?? "terminal") · \(Crew.since(item.session.startedAt))")
                    .foregroundStyle(.secondary))
                .font(.caption).lineLimit(1)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        if item.session.background {
            Button { vm.attach(item) } label: { row }
                .buttonStyle(.hoverRow)
                .help("Open the session (\(terminal.label("claude attach")))")
                .contextMenu { stopButton(item) }
        } else if let pr {
            Button { selected = pr } label: { row }
                .buttonStyle(.hoverRow)
                .help("A terminal session. Click for the PR.")
                .contextMenu { showButton(item); stopButton(item) }
        } else {
            Button { vm.show(item) } label: { row }
                .buttonStyle(.hoverRow)
                .help("A terminal session. Click to bring its tab to the front.")
                .contextMenu { showButton(item); stopButton(item) }
        }
    }

    /// Terminal sessions only: an agent view session's row already opens it.
    private func showButton(_ item: CrewItem) -> some View {
        Button("Show session", systemImage: "macwindow") { vm.show(item) }
            .help("Bring its window to the front (iTerm2, Terminal or VS Code)")
    }

    private func stopButton(_ item: CrewItem) -> some View {
        Button("Stop session", systemImage: "stop.circle") { vm.stop(item) }
            .help(item.session.background ? "claude stop: the conversation is kept, and claude attach resumes it"
                                          : "Ends its claude process: the conversation is kept, and claude --resume reopens it")
    }

    /// "3 wait on you · 5 on others", parked PRs left out.
    private func moveSummary(_ sections: [(group: MyGroup, prs: [FeedbackPR])]) -> some View {
        func count(_ g: MyGroup) -> Int { sections.first { $0.group == g }?.prs.count ?? 0 }
        return Text(verbatim: "\(count(.yours)) wait on you · \(count(.waiting)) on others")
            .font(.caption).foregroundStyle(.secondary)
    }

    /// `quiet`: nothing new to show (or dismissed), so the line says when it was opened instead.
    private func feedbackRow(_ f: FeedbackPR, quiet: Bool = false, hint: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                numberedTitle(f.pr.number, f.pr.title)
                if f.pr.isDraft { draftBadge }
                Spacer(minLength: 4)
                if let item = vm.crewItem(for: f.pr) { CrewBadge(item: item) }
                if f.move == .yours(.needsReviewer) {
                    Label("Needs a reviewer", systemImage: "person.badge.plus").font(.caption).foregroundStyle(.orange)
                }
                StatusBadge(feedback: f)
                DecisionBadge(decision: f.decision)
            }
            if quiet {
                metaLine(f.pr.repository.nameWithOwner, "",
                         ((hint ? f.moveHint : nil).map { "\($0) · " } ?? "")
                            + (f.pr.createdAt.map { "opened \(age($0))" } ?? "updated \(age(f.pr.updatedAt))"))
            } else {
                metaLine(f.pr.repository.nameWithOwner, f.latestBy, " \(age(f.latestAt)) · \(f.summary)")
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    // MARK: crew

    /// Claude sessions in your watched repos, waiting on you first, idle ones folded.
    private var crewList: some View {
        Group {
            if vm.allCrew.isEmpty {
                empty("person.2", "No Claude sessions in your repos.")
            } else {
                List {
                    sectionHeader("Crew", count: vm.crew.count)
                        .listRowSeparator(.hidden)
                    if let notice = vm.terminalNotice {
                        Text(notice).font(.caption).foregroundStyle(.secondary)
                            .listRowSeparator(.hidden)
                    }
                    ForEach(vm.crew) { item in
                        crewRow(item)
                            .listRowSeparator(.hidden)
                    }
                    if !vm.idleCrew.isEmpty {
                        Button { showIdleCrew.toggle() } label: {
                            HStack(spacing: 4) {
                                Text(verbatim: "Idle \(vm.idleCrew.count)")
                                Image(systemName: showIdleCrew ? "chevron.down" : "chevron.right").font(.caption2.bold())
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.hoverRow)
                        .help("\(showIdleCrew ? "Hide" : "Show") sessions at their prompt, some may have no visible window")
                        .listRowSeparator(.hidden)
                        ForEach(showIdleCrew ? vm.idleCrew : []) { item in
                            crewRow(item)
                                .opacity(0.55)
                                .listRowSeparator(.hidden)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    // MARK: helpers

    /// The line under a row's title: "acme/api · lina · New commits since your review", with the
    /// person in normal text and the rest in grey. The repo lives here, not on a line of its own.
    private func metaLine(_ repo: String, _ person: String, _ rest: String) -> some View {
        (Text(verbatim: "\(repo) · ").foregroundStyle(.secondary)
            + Text(verbatim: person).foregroundStyle(.primary)
            + Text(verbatim: rest).foregroundStyle(.secondary))
            .font(.caption).lineLimit(2)
    }

    private var draftBadge: some View {
        Text("DRAFT").font(.caption2).foregroundStyle(.secondary)
            .padding(.horizontal, 4).background(.quaternary, in: Capsule())
    }

    /// "#482 Add CSV export", with the number in grey.
    private func numberedTitle(_ number: Int, _ title: String) -> some View {
        (Text(verbatim: "#\(number) ").foregroundStyle(.secondary) + Text(verbatim: title))
            .font(.body.weight(.medium)).lineLimit(2)
    }

    private func title(_ t: Tab) -> String {
        switch t {
        case .reviewing where vm.yourTurnCount > 0: return "\(t.rawValue) (\(vm.yourTurnCount))"
        case .mine where vm.yourMoveCount > 0: return "\(t.rawValue) (\(vm.yourMoveCount))"
        case .mentions where !vm.visibleMentions.isEmpty: return "\(t.rawValue) (\(vm.visibleMentions.count))"
        case .crew where !vm.crew.isEmpty: return "\(t.rawValue) (\(vm.crew.count))"
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
                Button("Open PR", systemImage: "arrow.up.right.square") { open(pr.url) }
                    .help("Open this PR on GitHub")
                Button("Files", systemImage: "doc.text") { open(pr.url + "/files") }
                    .help("Open the changed files on GitHub")
            }
            .buttonStyle(.hoverBorderless)

            Text(pr.title).font(.headline)
            Text(verbatim: "\(pr.repository.nameWithOwner) #\(pr.number) · \(pr.author.login)")
                .font(.caption).foregroundStyle(.secondary)

            statusLine

            if let f = vm.feedback(for: pr) {
                HStack {
                    DecisionBadge(decision: f.decision)
                    Text(f.threads + f.reviews + f.comments == 0
                         ? "\(f.summary)."
                         : "New feedback: \(f.summary). Latest from \(f.latestBy).")
                        .font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button("Dismiss", systemImage: "xmark") { vm.dismissFeedback(f) }
                        .buttonStyle(.hoverBorderless).font(.caption)
                        .help("Hide this feedback until someone adds more")
                }
            }

            if let r = vm.reply(for: pr) {
                HStack {
                    Text("\(r.waiting) of your review threads \(r.waiting == 1 ? "has a reply" : "have replies") waiting. "
                        + "Latest from \(r.latestBy).")
                        .font(.caption).foregroundStyle(.orange)
                    Spacer()
                    if let rv = vm.reviewingPR(for: pr), !rv.isRequested {
                        Button("Mute until something happens", systemImage: "bell.slash") { vm.muteUntilSomethingHappens(rv) }
                            .buttonStyle(.hoverBorderless).font(.caption)
                            .help("Move this PR to Muted until a new commit, comment or review arrives")
                    } else {
                        Button("Dismiss", systemImage: "xmark") { vm.dismissReplies(r) }
                            .buttonStyle(.hoverBorderless).font(.caption)
                            .help("Hide this until someone replies again")
                    }
                }
            }

            if !vm.isMine(pr), case .idle = vm.state(for: pr), vm.hasOlderReview(pr) {
                if let earlier = vm.earlierReview(for: pr) {
                    Text("New commits since your review of \(earlier.pr.versionLabel). Review just those, "
                         + "checked against your earlier notes, or run a full review.")
                        .font(.caption).foregroundStyle(.orange)
                } else {
                    Text("This PR has new activity since your last review.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            actions.controlSize(.large)

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
        .onAppear { if let r = vm.reviewingPR(for: pr) { vm.markSeen(r) } }
    }

    /// The badges the PR's row shows, so the detail doesn't know less than the list.
    @ViewBuilder private var statusLine: some View {
        let mine = vm.isMine(pr) ? vm.myPRs.first { $0.pr.url == pr.url } : nil
        let reviewing = vm.isMine(pr) ? nil : vm.reviewingPR(for: pr)
        let crew = vm.crewItem(for: pr)
        if mine != nil || reviewing != nil || crew != nil {
            HStack(spacing: 8) {
                if let crew { CrewBadge(item: crew) }
                if let mine {
                    StatusBadge(feedback: mine)
                    if mine.botThreads > 0 {
                        Label("\(mine.botThreads) bot thread\(mine.botThreads == 1 ? "" : "s")", systemImage: "cpu")
                            .foregroundStyle(.secondary)
                    }
                }
                if let reviewing { ChecksIcon(state: reviewing.checks, labelled: true) }
            }
            .font(.caption)
        }
    }

    /// Quick-model summary of the comments, or the button to make one.
    @ViewBuilder private var summaryBox: some View {
        let quick = Agent.current.label(Agent.current.quick)
        let sinceReview = vm.summarySince(pr) != nil
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(sinceReview ? "Since your review, summarised" : "Feedback summary").font(.callout.bold())
                Text(quick).font(.caption).foregroundStyle(.secondary)
                Spacer()
                switch vm.summaryState(for: pr) {
                case .running:
                    ProgressView().controlSize(.small)
                case .done:
                    Button("Redo", systemImage: "arrow.counterclockwise") { vm.summarise(pr) }.buttonStyle(.hoverBorderless).font(.caption)
                        .help("Summarise the comments again")
                default:
                    Button(sinceReview ? "Summarise what happened" : "Summarise feedback", systemImage: "text.alignleft") { vm.summarise(pr) }.font(.caption)
                        .help("\(quick) reads the comments, not the code, and sums up who said what")
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
                Text(sinceReview
                     ? "A quick read of what people said since your review and what's waiting on you. It doesn't see the code."
                     : "A quick read of who said what and what's waiting on you. It doesn't see the code.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .card()
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
            if !vm.isMine(pr), let older = vm.olderReview(for: pr) {
                DisclosureGroup("Your earlier review of \(older.pr.versionLabel): \(ReviewPage.label(older))") { MarkdownView(text: older.text) }
                    .font(.caption)
            }
            if !vm.isMine(pr) {
                Text("Private notes appear here and are saved locally. Nothing is ever posted to GitHub.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var actions: some View {
        HStack {
            if vm.isMine(pr) {
                let action = vm.myPRAction(for: pr)
                if let action {
                    Button(terminalLabel(action.title), systemImage: TerminalApp.symbol) { vm.runMyPRAction(pr) }
                        .buttonStyle(.borderedProminent)
                }
                if action?.isMerge ?? true {
                    Button(terminalLabel(vm.myPRs.contains { $0.pr.url == pr.url && $0.hasFeedback } ? "Work through feedback" : "Open"), systemImage: TerminalApp.symbol) { vm.openTerminal(pr) }
                        .prominent(action == nil)
                }
            } else {
                reviewActions
            }
        }
        if vm.isMine(pr) {
            if let action = vm.myPRAction(for: pr) {
                Text("\(action.title) sends “\(action.command)” to \(Agent.current.appName), in your checkout of the PR's branch. Nothing is ever posted to GitHub without your OK.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Opens \(Agent.current.appName) with the reviews, threads and comments on this PR plus the current diff. Nothing is ever posted to GitHub.")
                    .font(.caption).foregroundStyle(.secondary)
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
        if let e = vm.error {
            Text(e).font(.caption).foregroundStyle(.red)
        }
    }

    @ViewState private var confirmDraft = false

    /// "Draft on GitHub": asks first, since this is the one thing that writes to GitHub.
    @ViewBuilder private func draftButton(_ text: String) -> some View {
        let count = DraftReview.comments(from: text).count
        if case .running = vm.draftState[pr.reviewKey] ?? .idle {
            ProgressView().controlSize(.small)
        } else {
            Button("Draft on GitHub", systemImage: "square.and.pencil") { confirmDraft = true }
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

    /// The full row when it fits; in the narrow popup, the buttons after the first show only
    /// their icon (with the title as tooltip) instead of truncating.
    private var reviewActions: some View {
        ViewThatFits(in: .horizontal) {
            reviewActionRow(compact: false)
            reviewActionRow(compact: true)
        }
    }

    @ViewBuilder private func reviewActionRow(compact: Bool) -> some View {
        HStack {
            switch vm.state(for: pr) {
            case .running:
                ProgressView().controlSize(.small)
                Text("\(Agent.current.name) is reading the diff…").font(.caption)
                Button("Cancel", systemImage: "stop.circle") { vm.cancelReview(pr) }.font(.caption)
                    .help("Stop this review")
            case .done(let text):
                Button(terminalLabel("Follow up"), systemImage: TerminalApp.symbol) { vm.openTerminal(pr) }
                    .prominent(!vm.verifyIsDue(pr))
                    .help("Continue in \(Agent.current.appName) with this PR and the review above")
                Button("Open in browser", systemImage: "arrow.up.right.square") {
                    let s = vm.savedReview(for: pr)
                    ReviewPage.open(pr: pr, text: text, label: s.map(ReviewPage.label), date: s?.date)
                }
                .help("Open this review as a web page")
                .iconOnly(compact)
                draftButton(text).iconOnly(compact)
                Button("Re-run", systemImage: "arrow.counterclockwise") { vm.rerun(pr) }
                    .help("Run the same review again on this version")
                    .iconOnly(compact)
                Button("Copy", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .help("Copy the review as Markdown")
                .iconOnly(compact)
            default:
                if let earlier = vm.earlierReview(for: pr) {
                    Button("Review changes since \(earlier.pr.versionLabel)", systemImage: "sparkles") { vm.reviewChanges(pr, since: earlier) }
                        .prominent(!vm.verifyIsDue(pr))
                        .help("Review only the commits since \(earlier.pr.versionLabel)")
                    Button("Full review", systemImage: "sparkles") { vm.review(pr) }
                        .help("Review the whole diff again")
                        .iconOnly(compact)
                    terminalButton.iconOnly(compact)
                } else if runsReviewCommand {
                    terminalButton.prominent(!vm.verifyIsDue(pr))
                    Button("Review with \(Agent.current.name)", systemImage: "sparkles") { vm.review(pr) }
                        .help("Quick read-only review with the built-in prompt; notes are saved here")
                        .iconOnly(compact)
                } else {
                    Button("Review with \(Agent.current.name)", systemImage: "sparkles") { vm.review(pr) }
                        .prominent(!vm.verifyIsDue(pr))
                        .help("\(Agent.current.name) reads the diff and writes private notes here. Nothing is posted to GitHub.")
                    terminalButton.iconOnly(compact)
                }
            }
        }
    }

    private var terminalButtonTitle: String { terminalLabel(vm.hasFollowUpContext(pr) ? "Follow up" : "Review") }

    private var terminalButton: some View {
        Button(terminalButtonTitle, systemImage: TerminalApp.symbol) { vm.openTerminal(pr) }
            .help(vm.hasFollowUpContext(pr)
                  ? "Continue in \(Agent.current.appName) with this PR and your earlier review"
                  : "Review this PR in \(Agent.current.appName) in your terminal")
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
    @AppStorage(MenuBarCount.requestsKey) private var countRequests = true
    @AppStorage(MenuBarCount.reviewedKey) private var countReviewed = true
    @AppStorage(MenuBarCount.myPRsKey) private var countMyPRs = true
    @AppStorage(MenuBarCount.mentionsKey) private var countMentions = true
    @AppStorage(MenuBarCount.crewKey) private var countCrew = true
    @AppStorage(TerminalApp.key) private var terminalRaw = ""
    @AppStorage(ClaudeSettings.reviewCommandKey) private var reviewCommand = ClaudeSettings.reviewCommandDefault
    @AppStorage(ClaudeSettings.verifyCommandKey) private var verifyCommand = ClaudeSettings.verifyCommandDefault
    @AppStorage(ClaudeSettings.myPRCommandKey) private var myPRCommand = ClaudeSettings.myPRCommandDefault
    @AppStorage(Backend.reviewStyleKey) private var reviewStyle = Backend.reviewStyleDefault
    @AppStorage(TerminalApp.Worktree.nextToCloneKey) private var worktreesNextToClone = false
    @AppStorage(NotifySettings.requestsKey) private var notifyRequests = true
    @AppStorage(NotifySettings.repliesKey) private var notifyReplies = true
    @AppStorage(NotifySettings.feedbackKey) private var notifyFeedback = true
    @AppStorage(NotifySettings.pushedKey) private var notifyPushed = true
    @AppStorage(NotifySettings.resolvedKey) private var notifyAllResolved = true
    @AppStorage(NotifySettings.verdictsKey) private var notifyVerdicts = true
    @AppStorage(NotifySettings.mentionsKey) private var notifyMentions = true
    @AppStorage(NotifySettings.crewKey) private var notifyCrew = true
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
                    .buttonStyle(.hoverBorderless).font(.caption)
                }
            }

            if repos.isEmpty {
                Label("No repos yet. Add one above.", systemImage: "tray")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
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
                            .buttonStyle(.hoverBorderless)
                            .help(folders[r.lowercased()] == nil
                                  ? "Choose the local checkout of \(r): Terminal sessions start there"
                                  : "Change the local folder (Terminal sessions start there)")
                            .contextMenu {
                                if folders[r.lowercased()] != nil {
                                    Button("Forget folder") { RepoList.setFolder(nil, for: r); loadFolders() }
                                }
                            }
                            Button { remove(r) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.hoverBorderless)
                                .help("Remove \(r)")
                                .accessibilityLabel("Remove \(r)")
                        }
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
                .frame(height: min(150, max(48, CGFloat(repos.count) * 44)))
                .onAppear(perform: loadFolders)
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
            VStack(alignment: .leading, spacing: 4) {
                Text("Review command").font(.headline)
                Text(agentRaw == Agent.codex.rawValue
                     ? "Claude Code only. Codex reviews use the built-in prompt."
                     : "The first message of a new review in the terminal, with {url} as the PR's link. "
                       + "Leave it empty for the built-in review prompt.")
                    .font(.caption2).foregroundStyle(.secondary)
                TextField("Review command", text: $reviewCommand, prompt: Text("Built-in review prompt"))
                    .labelsHidden()
                    .disabled(agentRaw == Agent.codex.rawValue)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Verify command").font(.headline)
                Text(agentRaw == Agent.codex.rawValue
                     ? "Claude Code only."
                     : "Sent by Verify fixes (PRs where you have review threads), with {url} as the PR's link. "
                       + "Leave it empty to hide the button.")
                    .font(.caption2).foregroundStyle(.secondary)
                TextField("Verify command", text: $verifyCommand, prompt: Text("No Verify fixes button"),
                          axis: .vertical)
                    .lineLimit(1...4)
                    .labelsHidden()
                    .disabled(agentRaw == Agent.codex.rawValue)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Triage feedback command").font(.headline)
                Text(agentRaw == Agent.codex.rawValue
                     ? "Claude Code only."
                     : "Sent by Triage feedback on your own PRs with feedback or failing CI, in your checkout of "
                       + "the PR's branch. {url} is the PR's link. Empty: the built-in prompt.")
                    .font(.caption2).foregroundStyle(.secondary)
                TextField("Triage feedback command", text: $myPRCommand, prompt: Text("Built-in Work through feedback prompt"))
                    .labelsHidden()
                    .disabled(agentRaw == Agent.codex.rawValue)
            }
            Toggle("Put PR worktrees next to the clone", isOn: $worktreesNextToClone)
            Text(worktreesNextToClone
                 ? "Each PR is checked out in <clone>-worktrees/pr-<number>, e.g. gauss-worktrees/pr-42."
                 : "Each PR is checked out in ReviewBar's Application Support folder.")
                .font(.caption2).foregroundStyle(.secondary)

            Divider()
            Text("Review prompt").font(.headline)
            Text("How reviews are written and how suggested comments are worded. Used by every review and re-review, "
                 + "and by new reviews in the terminal unless a Review command is set.")
                .font(.caption2).foregroundStyle(.secondary)
            TextEditor(text: $reviewStyle)
                .font(.system(.caption, design: .monospaced))
                .frame(height: 220)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
                // Text equal to the built-in style isn't saved, so later changes to it still apply.
                .onChange(of: reviewStyle) { _, v in
                    if v == Backend.reviewStyleDefault { UserDefaults.standard.removeObject(forKey: Backend.reviewStyleKey) }
                }
            HStack {
                if Backend.reviewStyle(saved: reviewStyle) != Backend.reviewStyleDefault {
                    Text("Edited").font(.caption).foregroundStyle(.orange)
                }
                Spacer()
                Button("Reset to built-in") { UserDefaults.standard.removeObject(forKey: Backend.reviewStyleKey) }
                    .disabled(reviewStyle == Backend.reviewStyleDefault)
            }
            DisclosureGroup("Full prompt") {
                Text(Backend.reviewPromptPreview(style: reviewStyle))
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption)
            Text("The rules and the verdict and finding markers around it are fixed: ReviewBar reads the verdict and "
                 + "findings from them. How comments are worded is up to the text above. Empty means the built-in prompt.")
                .font(.caption2).foregroundStyle(.secondary)

            Divider()
            Text("Pull requests").font(.headline)
            Toggle("Include draft PRs", isOn: $includeDrafts)
            Text("Applies to Reviewing. Your own drafts always show in My PRs.")
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
            Toggle("A Claude session needs you (Claude Code only)", isOn: $notifyCrew)
            notificationHint

            Divider()
            Text("Panel").font(.headline)
            Text("Menu bar number counts")
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Review requests (awaiting your review)", isOn: $countRequests)
                Toggle("New commits or replies on PRs you reviewed", isOn: $countReviewed)
                Toggle("Feedback on your PRs", isOn: $countMyPRs)
                Toggle("Mentions", isOn: $countMentions)
                Toggle("Claude sessions that need you", isOn: $countCrew)
            }
            .padding(.leading, 12)
            Text(countRequests || countReviewed || countMyPRs || countMentions || countCrew
                 ? "Each PR counts once, even when it's in more than one of these. PRs muted in Reviewing don't count "
                   + "as requests or activity, but a mention still counts."
                 : "Nothing is counted, so the menu bar shows only the icon.")
                .font(.caption2).foregroundStyle(.secondary)
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
                .buttonStyle(.hoverBorderless).font(.caption2)
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
    /// "Checks failing" / "Checks running" beside the icon, like My PRs' badges. Passing stays a bare ✓.
    var labelled = false

    var body: some View {
        switch state ?? "" {
        case "SUCCESS":
            Image(systemName: "checkmark.circle").foregroundStyle(.green).help("Checks passed")
        case "FAILURE", "ERROR":
            icon("xmark.octagon.fill", "Checks failing").foregroundStyle(.red)
        case "PENDING", "EXPECTED":
            icon("clock", "Checks running").foregroundStyle(.orange)
        default:
            EmptyView()
        }
    }

    @ViewBuilder private func icon(_ symbol: String, _ text: String) -> some View {
        if labelled { Label(text, systemImage: symbol) } else { Image(systemName: symbol).help(text) }
    }
}

/// A Claude session on this PR: waiting on you (orange) or at work.
struct CrewBadge: View {
    let item: CrewItem

    var body: some View {
        Label(item.session.needsMe ? "Claude needs you" : "Claude working",
              systemImage: item.session.needsMe ? "questionmark.bubble.fill" : "ellipsis.bubble")
            .font(.caption)
            .foregroundStyle(item.session.needsMe ? Color.orange : Color.secondary)
            .help(item.session.background ? "An agent view session (see the Crew tab)" : "A Claude session in a terminal window")
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

extension View {
    /// The filled accent style when `on`, the regular bordered one otherwise.
    @ViewBuilder func prominent(_ on: Bool) -> some View {
        if on { buttonStyle(.borderedProminent) } else { self }
    }

    /// A labelled button showing only its icon when `on`; its tooltip says what it does.
    @ViewBuilder func iconOnly(_ on: Bool) -> some View {
        if on { labelStyle(.iconOnly) } else { self }
    }
}
