import SwiftUI
import AppKit

/// "Since your review" on a PR you reviewed: commits since, your threads, other reviewers.
struct ReviewingDetailBox: View {
    @EnvironmentObject var vm: ReviewViewModel
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
                threads(d.myThreads)
                reviewers(d.reviewers(reviewing.verdicts))
            } else if load.loading {
                Text("Loading threads and commits…").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        .onAppear { vm.loadDetail(reviewing) }
    }

    @ViewBuilder private func commits(_ c: ReviewingDetail.Commits) -> some View {
        let isNews: Bool = if case .same = c { false } else { true }
        Text(c.summary).font(.caption).foregroundStyle(isNews ? .orange : .secondary)
        if case .new(let count, let list) = c {
            ForEach(list.prefix(Self.maxCommits), id: \.sha) { commit in
                Text(verbatim: "\(commit.sha) \(commit.message)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if count > min(list.count, Self.maxCommits) {
                Text("+ \(count - min(list.count, Self.maxCommits)) more").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func threads(_ threads: [ReviewingDetail.MyThread]) -> some View {
        if !threads.isEmpty {
            let resolved = threads.filter { $0.state == .resolved }.count
            Text("Your threads · \(resolved)/\(threads.count) resolved").font(.caption.bold()).padding(.top, 2)
            ForEach(Array(threads.enumerated()), id: \.offset) { _, t in
                Button { if let s = t.url, let u = URL(string: s) { NSWorkspace.shared.open(u) } } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(t.stateText).foregroundStyle(color(t.state))
                            Text(verbatim: t.location).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.head)
                        }
                        Text(verbatim: t.snippet).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open this thread on GitHub")
            }
        }
    }

    @ViewBuilder private func reviewers(_ people: [ReviewingDetail.Reviewer]) -> some View {
        if !people.isEmpty {
            Text("Other reviewers").font(.caption.bold()).padding(.top, 2)
            ForEach(people, id: \.login) { p in
                Text(verbatim: "\(p.login) · \(p.text)").font(.caption)
            }
        }
    }

    private func color(_ s: ReviewingDetail.MyThread.State) -> Color {
        switch s {
        case .replied: .blue
        case .open: .primary
        case .resolved: .green
        }
    }
}
