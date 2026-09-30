import Foundation
import AppKit

/// Where "… in Terminal" opens Claude Code.
enum TerminalApp: String, CaseIterable, Identifiable {
    case terminal, iterm, ghostty, wezterm, kitty, alacritty
    /// For any other terminal (Warp, …): copy a command to paste.
    case copy

    static let key = "terminalApp"
    /// Picked when nothing was chosen: the first one installed. People who install another
    /// terminal usually use it, so Terminal comes last.
    static let automaticOrder: [TerminalApp] = [.ghostty, .iterm, .wezterm, .kitty, .alacritty, .terminal]

    var id: String { rawValue }

    var name: String {
        switch self {
        case .terminal: return "Terminal"
        case .iterm: return "iTerm2"
        case .ghostty: return "Ghostty"
        case .wezterm: return "WezTerm"
        case .kitty: return "kitty"
        case .alacritty: return "Alacritty"
        case .copy: return "Copy command"
        }
    }

    /// For button labels: "Follow up in Ghostty", or "Copy follow-up command".
    var buttonTarget: String { self == .copy ? "any terminal (copies a command)" : name }

    /// "Follow up in Ghostty", or "Follow up (copy command)" when no terminal can be driven.
    func label(_ verb: String) -> String { self == .copy ? "\(verb) (copy command)" : "\(verb) in \(name)" }

    /// The icon on every button that opens (or copies a command for) your terminal.
    static let symbol = "apple.terminal"

    var bundleID: String? {
        switch self {
        case .terminal: return "com.apple.Terminal"
        case .iterm: return "com.googlecode.iterm2"
        case .ghostty: return "com.mitchellh.ghostty"
        case .wezterm: return "com.github.wez.wezterm"
        case .kitty: return "net.kovidgoyal.kitty"
        case .alacritty: return "org.alacritty"
        case .copy: return nil
        }
    }

    /// Where the app is installed; nil if it isn't. "Copy command" needs no app.
    var appURL: URL? {
        bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    }

    var isInstalled: Bool { self == .copy || appURL != nil }

    /// Installed terminals plus "Copy command", in menu order.
    static var installed: [TerminalApp] { allCases.filter(\.isInstalled) }

    /// The saved choice if it's still installed, else the automatic pick.
    static var chosen: TerminalApp {
        resolve(saved: UserDefaults.standard.string(forKey: key) ?? "", installed: installed)
    }

    /// Pure, for tests. An empty or unknown saved value, or an app that has since been
    /// uninstalled, means automatic.
    static func resolve(saved: String, installed: [TerminalApp]) -> TerminalApp {
        if let app = TerminalApp(rawValue: saved), installed.contains(app) { return app }
        return automaticOrder.first(where: installed.contains) ?? .copy
    }

    /// Shell script the terminal runs. It uses your login PATH (terminals started with a command
    /// may not read your shell config), reads and deletes the prompt file (it holds the diff),
    /// deletes itself, starts Claude, and leaves you at a normal shell when Claude exits.
    /// Exits quietly if the prompt is already gone: Ghostty can run a launch command twice. Pure, for tests.
    /// `checkout` is the repo's local clone plus where this PR's worktree goes, if a folder is set.
    static func launcherScript(claude: String, promptFile: String, path: String,
                               checkout: Worktree? = nil) -> String {
        """
        #!/bin/zsh
        \(path.isEmpty ? "" : "export PATH=\(q(path))")
        [[ -f \(q(promptFile)) ]] || exit 0
        \(checkout?.script ?? "")
        prompt="$(cat \(q(promptFile)))"
        rm -f \(q(promptFile)) "$0"
        \(claude) "$prompt"
        exec "${SHELL:-/bin/zsh}" -l

        """
    }

    /// A separate git worktree per PR, at the PR's head commit, so your own clone (its branch,
    /// its uncommitted changes) is never touched. Works for PRs from forks too (pull/N/head).
    struct Worktree: Equatable {
        let repoFolder: String
        let path: String
        let number: Int

        var ref: String { "refs/reviewbar/pr-\(number)" }

        /// Shell lines: fetch the PR head, create or update the worktree, cd into it. Any failure
        /// falls back to the clone itself, with a message. Pure, for tests.
        var script: String {
            let repo = q(repoFolder), wt = q(path)
            return """
            print "Preparing a worktree for PR #\(number)…"
            if git -C \(repo) fetch --quiet origin +pull/\(number)/head:\(ref); then
              git -C \(repo) worktree prune
              if [[ -d \(wt) ]]; then
                git -C \(wt) checkout --quiet --detach \(ref) \
                  || print "Kept the worktree as it is: it has local changes."
              else
                mkdir -p "$(dirname \(wt))"
                git -C \(repo) worktree add --quiet --detach \(wt) \(ref)
              fi
            fi
            if [[ -d \(wt) ]]; then cd \(wt); else print "Couldn't make a worktree; starting in your clone."; cd \(repo); fi
            print "In $PWD at $(git rev-parse --short HEAD 2>/dev/null)"
            """
        }

        static let nextToCloneKey = "worktreesNextToClone"

        /// Worktrees live under Application Support, never inside your clone. With `nextToClone`
        /// (Settings › Terminal) they go beside it instead: ~/code/gauss → ~/code/gauss-worktrees/pr-7.
        static func forPR(_ pr: PR, repoFolder: String,
                          nextToClone: Bool = UserDefaults.standard.bool(forKey: nextToCloneKey)) -> Worktree {
            forPR(pr.number, repo: pr.repository.nameWithOwner, repoFolder: repoFolder, nextToClone: nextToClone)
        }

        static func forPR(_ number: Int, repo: String, repoFolder: String, nextToClone: Bool) -> Worktree {
            let path: URL
            if nextToClone {
                let clone = URL(fileURLWithPath: repoFolder, isDirectory: true).standardized
                path = clone.deletingLastPathComponent()
                    .appendingPathComponent("\(clone.lastPathComponent)-worktrees/pr-\(number)")
            } else {
                let name = repo.replacingOccurrences(of: "/", with: "-")
                path = Store.dir.appendingPathComponent("worktrees/\(name)/pr-\(number)")
            }
            return Worktree(repoFolder: repoFolder, path: path.path, number: number)
        }

        /// One entry of `git worktree list --porcelain`.
        struct Listed: Equatable {
            let path: String
            let detached: Bool
        }

        /// Parses `git worktree list --porcelain`: blocks of `worktree <path>`, `HEAD <sha>`, then
        /// `detached` or `branch <ref>`, separated by blank lines. Pure, for tests.
        static func parseList(_ porcelain: String) -> [Listed] {
            porcelain.components(separatedBy: "\n\n").compactMap { block in
                var path: String?, detached = false
                for line in block.split(separator: "\n").map(String.init) {
                    if line.hasPrefix("worktree ") { path = String(line.dropFirst("worktree ".count)) }
                    else if line == "detached" { detached = true }
                }
                return path.map { Listed(path: $0, detached: detached) }
            }
        }

        /// The worktrees ReviewBar made for `repo`: named `pr-<N>`, exactly where `forPR` puts
        /// PR N under either location setting, and detached. Your own worktrees (a branch checked
        /// out, or any other folder) never match. Pure, for tests.
        static func ours(_ listed: [Listed], repo: String, repoFolder: String) -> [Worktree] {
            func real(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
            return listed.compactMap { w in
                let name = (w.path as NSString).lastPathComponent
                guard w.detached, name.hasPrefix("pr-"), let n = Int(name.dropFirst(3)), n > 0 else { return nil }
                let candidates = [true, false].map { forPR(n, repo: repo, repoFolder: repoFolder, nextToClone: $0) }
                return candidates.first { real($0.path) == real(w.path) }
            }
        }

        /// Shell lines that remove this worktree and its ref only if nothing would be lost: the
        /// ref exists, `git status` is empty (ignored files such as a copied `vendor/` don't count;
        /// untracked ones do, whatever `status.showUntrackedFiles` says), and HEAD and every commit
        /// made in the worktree are the PR's last head on GitHub or already in the ref, so no
        /// unpushed commit goes, even one a relaunch moved HEAD away from (it's only in the reflog,
        /// which the removal deletes). `git worktree remove` runs without `--force`.
        /// Exits non-zero when it keeps the worktree. Pure, for tests.
        func removeScript(finalHead: String?) -> String {
            let repo = q(repoFolder), wt = q(path), final = q(finalHead ?? "")
            return """
            cd \(wt) || exit 1
            git -C \(repo) rev-parse --verify --quiet \(ref) >/dev/null || exit 1
            [[ -z "$(git status --porcelain --untracked-files=all)" ]] || exit 1
            [[ "$(git rev-parse HEAD)" == \(final) ]] || git merge-base --is-ancestor HEAD \(ref) || exit 1
            for c in $(git log -g --format='%H %gs' HEAD | awk '$2 ~ /^(commit|cherry-pick|revert|merge|rebase|am)/ { print $1 }'); do
              git merge-base --is-ancestor $c \(ref) 2>/dev/null || git merge-base --is-ancestor $c \(final) 2>/dev/null || exit 1
            done
            cd /
            git -C \(repo) worktree remove \(wt) && git -C \(repo) update-ref -d \(ref)
            """
        }
    }

    enum Launch: Equatable {
        /// Run this executable with these arguments.
        case process(String, [String])
        /// Put this on the clipboard for the user to paste into a terminal.
        case copy(String)
    }

    /// How to open `launcher` in this terminal; `app` is its .app path. Pure, for tests.
    func launch(launcher: String, app: String) -> Launch {
        func appleScriptString(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        switch self {
        case .terminal:
            // Terminal runs it in a new window's shell; quoted for that shell.
            return .process("/usr/bin/osascript", ["-e", """
                tell application "Terminal"
                    activate
                    do script \(appleScriptString(q(launcher)))
                end tell
                """])
        case .iterm:
            return .process("/usr/bin/osascript", ["-e", """
                tell application "iTerm"
                    activate
                    create window with default profile command \(appleScriptString(launcher))
                end tell
                """])
        case .ghostty:
            // No AppleScript: a new Ghostty instance runs the command. Without the save-state
            // flag it would also reopen your previous tabs.
            return .process("/usr/bin/open", ["-na", app, "--args", "--window-save-state=never", "-e", launcher])
        case .wezterm:
            return .process(app + "/Contents/MacOS/wezterm", ["start", "--", launcher])
        case .kitty:
            return .process("/usr/bin/open", ["-na", app, "--args", launcher])
        case .alacritty:
            return .process("/usr/bin/open", ["-na", app, "--args", "-e", launcher])
        case .copy:
            return .copy("zsh \(q(launcher))")
        }
    }
}
