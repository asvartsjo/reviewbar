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
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Since your review").font(.caption.bold())
                Spacer()
                if load.loading { ProgressView().controlSize(.small) }
            }
            if let e = load.error {
                Text(e).font(.caption).foregroundStyle(.red)
            }
            if let d = load.detail {
                commits(d.commits)
                activity(d)
                threads(d)
                if !d.myThreads.isEmpty, reviewing.verifyIsDue { verifyButton }
                reviewers(d.reviewers(reviewing.verdicts))
            } else if load.loading {
                Text("Loading activity, threads and commits…").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
        .onAppear { vm.loadDetail(reviewing) }
    }

    @ViewBuilder private func commits(_ c: ReviewingDetail.Commits) -> some View {
        let isNews: Bool = if case .same = c { false } else { true }
        Text(c.summary).font(.caption).foregroundStyle(isNews ? .orange : .secondary)
        if case .new(let count, let list) = c {
            ForEach(list.prefix(Self.maxCommits), id: \.sha) { commit in
                (Text(verbatim: commit.sha).font(.caption.monospaced()).foregroundStyle(.secondary)
                    + Text(verbatim: " \(commit.message)").font(.caption))
                    .lineLimit(1)
            }
            if count > min(list.count, Self.maxCommits) {
                Text("+ \(count - min(list.count, Self.maxCommits)) more").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private static let isoParser = ISO8601DateFormatter()

    @ViewBuilder private func activity(_ d: ReviewingDetail) -> some View {
        let before = vm.previouslySeen(reviewing.pr)
        if d.activity.isEmpty {
            Text("No activity since your review").font(.caption).foregroundStyle(.secondary)
        } else {
            Text("Activity").font(.caption.bold()).padding(.top, 2)
            ForEach(Array(d.activity.enumerated()), id: \.offset) { _, a in
                let when = Self.isoParser.date(from: a.at)?.formatted(.relative(presentation: .named)) ?? ""
                Button { if let u = URL(string: a.url ?? reviewing.pr.url) { NSWorkspace.shared.open(u) } } label: {
                    HStack(spacing: 6) {
                        if let before, a.at > before { NewDot() }
                        Text(verbatim: a.text).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(when).foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open on GitHub")
            }
            if d.activityCapped {
                Button("Older activity is on GitHub") {
                    if let u = URL(string: reviewing.pr.url) { NSWorkspace.shared.open(u) }
                }
                .buttonStyle(.link).font(.caption)
            }
        }
    }

    @ViewBuilder private func threads(_ d: ReviewingDetail) -> some View {
        let threads = d.myThreads
        if !threads.isEmpty {
            let resolved = threads.filter { $0.state == .resolved }.count
            HStack(spacing: 0) {
                Text(verbatim: (["Your threads", "\(resolved)/\(threads.count) resolved"] + [d.openBySeverity].compactMap { $0 })
                    .joined(separator: " · "))
                if d.blockingOpen > 0 {
                    Text(verbatim: " · \(d.blockingOpen) blocking").foregroundStyle(.red)
                        .help("Open 🚨/🔴 threads: your pr-review skill says these block a merge")
                }
            }
            .font(.caption.bold()).padding(.top, 2)
            ForEach(Array(threads.enumerated()), id: \.offset) { _, t in
                Button { if let s = t.url, let u = URL(string: s) { NSWorkspace.shared.open(u) } } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: t.snippet).lineLimit(1)
                                .foregroundStyle(t.state == .resolved ? .secondary : .primary)
                            Text(verbatim: t.location).font(.caption2.monospaced()).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.head)
                        }
                        Spacer(minLength: 4)
                        Text(t.stateText).font(.caption2).foregroundStyle(color(t.state))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(color(t.state).opacity(0.5)))
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(t.fullText.isEmpty ? "Open this thread on GitHub" : t.fullText + "\n\nClick to open on GitHub")
            }
        }
    }

    /// Sends your Verify command (Settings › Terminal). Shown only once there's something to verify.
    @ViewBuilder private var verifyButton: some View {
        if Agent.current == .claude, ClaudeSettings.command(verifyCommand, url: reviewing.pr.url) != nil {
            let terminal = TerminalApp.resolve(saved: terminalRaw, installed: TerminalApp.installed)
            Button(terminal.label("Verify fixes")) { vm.verifyInTerminal(reviewing.pr) }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .help("Checks each of your threads against the commits since your review")
        }
    }

    @ViewBuilder private func reviewers(_ people: [ReviewingDetail.Reviewer]) -> some View {
        if !people.isEmpty {
            Text("Other reviewers").font(.caption.bold()).padding(.top, 2)
            ForEach(people, id: \.login) { p in
                HStack {
                    Text(verbatim: p.login)
                    Spacer(minLength: 4)
                    Text(verbatim: p.text).foregroundStyle(.secondary)
                }
                .font(.caption)
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
