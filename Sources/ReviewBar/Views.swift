import SwiftUI
import AppKit

private enum Tab: String, CaseIterable {
    case pending = "Awaiting me"
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
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

                if tab == .pending { pendingList } else { savedList }
            }
        }
        .frame(width: 480, height: 580)
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
            if let e = vm.error {
                Text(e).font(.caption).foregroundStyle(.red).padding(.horizontal, 10)
            }
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
            Text("\(s.pr.author.login) · reviewed \(s.date.formatted(.relative(presentation: .named)))")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    // MARK: helpers

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

            if case .idle = vm.state(for: pr), vm.hasOlderReview(pr) {
                Text("This PR has new activity since your last review. The older one is under Saved.")
                    .font(.caption).foregroundStyle(.orange)
            }

            actions

            Divider()
            ScrollView {
                Group {
                    switch vm.state(for: pr) {
                    case .done(let text): Text(rendered(text))
                    case .failed(let msg): Text(msg).foregroundStyle(.red)
                    default:
                        Text("Private notes appear here and are saved locally. Nothing is ever posted to GitHub.")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 12))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
    }

    @ViewBuilder private var actions: some View {
        HStack {
            switch vm.state(for: pr) {
            case .running:
                ProgressView().controlSize(.small)
                Text("Claude is reading the diff…").font(.caption)
            case .done(let text):
                Button("Follow up in Terminal") { vm.openTerminal(pr) }
                    .buttonStyle(.borderedProminent)
                Button("Re-run") { vm.review(pr) }
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            default:
                Button("Review with Claude") { vm.review(pr) }
                    .buttonStyle(.borderedProminent)
                Button("Review in Terminal") { vm.openTerminal(pr) }
            }
        }
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
    @AppStorage("owner") private var owner = ""
    @AppStorage("repos") private var repos = ""
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("GitHub org / owner").font(.caption).foregroundStyle(.secondary)
            TextField("e.g. your-org", text: $owner).textFieldStyle(.roundedBorder)

            Text("Repos to watch (one per line, `repo` or `org/repo`). Leave empty for the whole org.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $repos)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 200)
                .border(.quaternary)

            HStack {
                Spacer()
                Button("Save", action: done).buttonStyle(.borderedProminent)
            }
        }
        .padding(10)
    }
}
