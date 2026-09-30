import SwiftUI
import AppKit

/// "Since your review" on a PR you reviewed: commits and activity since, your threads, other reviewers.
struct ReviewingDetailBox: View {
    @EnvironmentObject var vm: ReviewViewModel
    @AppStorage(TerminalApp.key) private var terminalRaw = ""
    @AppStorage(ClaudeSettings.verifyCommandKey) private var verifyCommand = ClaudeSettings.verifyCommandDefault
    let reviewing: ReviewingPR

    /// Commits listed before "+ N more".
    static let maxCommits = 10

    var body: some View {
        let load = vm.detailLoad(for: reviewing.pr)
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                heading("Since your review")
                Spacer()
                if load.loading { ProgressView().controlSize(.small) }
            }
            if let e = load.error {
                Text(e).foregroundStyle(.red)
            }
            if let d = load.detail {
                commits(d.commits)
                activity(d)
                threads(d)
                reviewers(d.reviewers(reviewing.verdicts))
                if !d.myThreads.isEmpty, reviewing.verifyIsDue { verifyButton.padding(.top, 4) }
            } else if load.loading {
                Text("Loading activity, threads and commits…").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
        .onAppear { vm.loadDetail(reviewing) }
    }

    private func heading(_ text: String) -> some View {
        Text(text).font(.callout.bold())
    }

    /// Every line in the box sits after this column, so they line up whether or not it holds a dot.
    @ViewBuilder private func gutter(new: Bool = false) -> some View {
        if new { NewDot() } else { Color.clear.frame(width: 7, height: 7) }
    }

    private func line<Content: View>(new: Bool = false, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            gutter(new: new).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            content()
        }
    }

    /// The summary line only when it isn't just the count above a list of the commits.
    @ViewBuilder private func commits(_ c: ReviewingDetail.Commits) -> some View {
        switch c {
        case .new(let count, let list):
            ForEach(list.prefix(Self.maxCommits), id: \.sha) { commit in
                line {
                    (Text(verbatim: commit.sha).font(.callout.monospaced()).foregroundStyle(.secondary)
                        + Text(verbatim: " \(commit.message)"))
                        .lineLimit(1)
                }
            }
            if count > min(list.count, Self.maxCommits) {
                line { Text("+ \(count - min(list.count, Self.maxCommits)) more").foregroundStyle(.secondary) }
            }
        case .same:
            Text(c.summary).foregroundStyle(.secondary)
        default:
            Text(c.summary).foregroundStyle(.orange)
        }
    }

    private static let isoParser = ISO8601DateFormatter()

    @ViewBuilder private func activity(_ d: ReviewingDetail) -> some View {
        let before = vm.previouslySeen(reviewing.pr)
        if d.activity.isEmpty {
            Text("No activity since your review").foregroundStyle(.secondary)
        } else {
            heading("Activity").padding(.top, 4)
            ForEach(Array(d.activity.enumerated()), id: \.offset) { _, a in
                let when = Self.isoParser.date(from: a.at)?.formatted(.relative(presentation: .named)) ?? ""
                Button { if let u = URL(string: a.url ?? reviewing.pr.url) { NSWorkspace.shared.open(u) } } label: {
                    line(new: before.map { a.at > $0 } ?? false) {
                        Text(verbatim: a.text).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(when).font(.caption).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.hoverRow)
                .help("Open on GitHub")
            }
            if d.activityCapped {
                line {
                    Button("Older activity is on GitHub", systemImage: "arrow.up.right.square") {
                        if let u = URL(string: reviewing.pr.url) { NSWorkspace.shared.open(u) }
                    }
                    .buttonStyle(.link)
                    .pointingHand()
                }
            }
        }
    }

    @ViewBuilder private func threads(_ d: ReviewingDetail) -> some View {
        let threads = d.myThreads
        if !threads.isEmpty {
            let resolved = threads.filter { $0.state == .resolved }.count
            HStack(spacing: 0) {
                heading((["Your threads", "\(resolved)/\(threads.count) resolved"] + [d.openBySeverity].compactMap { $0 })
                    .joined(separator: " · "))
                if d.blockingOpen > 0 {
                    Text(verbatim: " · \(d.blockingOpen) blocking").font(.callout.bold()).foregroundStyle(.red)
                        .help("Open 🚨/🔴 threads: your pr-review skill says these block a merge")
                }
            }
            .padding(.top, 4)
            ForEach(Array(threads.enumerated()), id: \.offset) { _, t in
                Button { if let s = t.url, let u = URL(string: s) { NSWorkspace.shared.open(u) } } label: {
                    line {
                        (Text(verbatim: t.snippet)
                            + Text(verbatim: "  \(t.location)").font(.caption.monospaced()).foregroundStyle(.secondary))
                            .foregroundStyle(t.state == .resolved ? .secondary : .primary)
                            .lineLimit(2)
                        Spacer(minLength: 4)
                        Text(t.stateText).font(.caption).foregroundStyle(color(t.state))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(color(t.state).opacity(0.5)))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.hoverRow)
                .help(t.fullText.isEmpty ? "Open this thread on GitHub" : t.fullText + "\n\nClick to open on GitHub")
            }
        }
    }

    /// Sends your Verify command (Settings › Terminal). Shown only once there's something to verify.
    @ViewBuilder private var verifyButton: some View {
        if Agent.current == .claude, ClaudeSettings.command(verifyCommand, url: reviewing.pr.url) != nil {
            let terminal = TerminalApp.resolve(saved: terminalRaw, installed: TerminalApp.installed)
            Button(terminal.label("Verify fixes"), systemImage: TerminalApp.symbol) { vm.verifyInTerminal(reviewing.pr) }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .help("Checks each of your threads against the commits since your review")
        }
    }

    @ViewBuilder private func reviewers(_ people: [ReviewingDetail.Reviewer]) -> some View {
        if !people.isEmpty {
            heading("Other reviewers").padding(.top, 4)
            ForEach(people, id: \.login) { p in
                line {
                    Text(verbatim: p.login)
                    Spacer(minLength: 4)
                    Text(verbatim: p.text).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func color(_ s: ReviewingDetail.MyThread.State) -> Color {
        switch s {
        case .replied: .blue
        case .open: .secondary
        case .resolved: .green
        }
    }
}

/// Marks something that changed since you last opened the PR, like unread mail.
struct NewDot: View {
    var body: some View {
        Circle().fill(.blue).frame(width: 7, height: 7).help("New since you last opened this PR")
    }
}
