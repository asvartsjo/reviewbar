import Foundation

/// The one-click next step on one of my PRs: my own command (Settings › Terminal), run in the
/// checkout that has the PR's branch, so fixes are committed where I work.
enum MyPRAction: Equatable {
    case feedback(command: String)
    case merge(command: String)

    var command: String {
        switch self {
        case .feedback(let c), .merge(let c): c
        }
    }

    var isMerge: Bool { if case .merge = self { true } else { false } }

    var title: String {
        switch self {
        case .feedback: "Triage feedback"
        case .merge: "Merge check"
        }
    }

    /// Feedback or failing CI gets the feedback command, ready to merge the merge command; a conflict,
    /// a draft or a PR waiting on others gets none. Nil also when that command is empty. Pure, for tests.
    static func `for`(_ f: FeedbackPR, feedbackCommand: String?, mergeCommand: String?) -> MyPRAction? {
        switch f.move {
        case .yours(.feedback), .yours(.checksFailing): feedbackCommand.map { .feedback(command: $0) }
        case .yours(.merge): mergeCommand.map { .merge(command: $0) }
        default: nil
        }
    }

    /// The worktree, or the clone itself, that has `branch` checked out. Git allows only one. A
    /// worktree whose folder was deleted stays listed until git prunes it, so it is skipped.
    static func checkout(of branch: String, in listed: [TerminalApp.Worktree.Listed]) -> String? {
        listed.first { $0.branch == "refs/heads/\(branch)" && FileManager.default.fileExists(atPath: $0.path) }?.path
    }

    /// Where a new checkout of `branch` goes: beside ReviewBar's `pr-<N>` worktrees, named after the
    /// branch (`atanas/fix` → `atanas-fix`), so it never takes the place of the PR's review worktree.
    /// Pure, for tests.
    static func newCheckoutPath(of branch: String, repo: String, repoFolder: String, nextToClone: Bool) -> String {
        TerminalApp.Worktree.folder(repo: repo, repoFolder: repoFolder, nextToClone: nextToClone)
            .appendingPathComponent(branch.replacingOccurrences(of: "/", with: "-")).path
    }

    /// Shell lines that add a worktree on `branch` at `path`. The branch is fetched first, so one that
    /// is only on origin becomes a local branch tracking it; a local branch is checked out as it is.
    /// Pruning first frees a branch whose worktree folder was deleted. Pure, for tests.
    static func makeCheckoutScript(branch: String, repoFolder: String, path: String) -> String {
        let repo = q(repoFolder), wt = q(path)
        return """
        git -C \(repo) worktree prune || exit 1
        mkdir -p "$(dirname \(wt))" || exit 1
        git -C \(repo) fetch --quiet origin \(q(branch)) 2>/dev/null
        git -C \(repo) worktree add --quiet \(wt) \(q(branch))
        """
    }
}

extension Backend {
    /// The checkout of `branch` in the repo's local clone, read from `git worktree list`; nil when the
    /// repo has no clone or no checkout has that branch. Read only: never switches a branch.
    static func checkout(of branch: String, repo: String) async -> String? {
        guard let folder = RepoList.folder(for: repo),
              let list = try? await sh("git -C \(q(folder)) worktree list --porcelain") else { return nil }
        return MyPRAction.checkout(of: branch, in: TerminalApp.Worktree.parseList(list))
    }

    /// Adds a worktree on `branch` (`MyPRAction.makeCheckoutScript`) for a PR with no checkout of its
    /// branch, and returns its path. The clone's own branch is never switched. Throws git's error.
    static func makeCheckout(of branch: String, repo: String) async throws -> String {
        guard let folder = RepoList.folder(for: repo) else {
            throw ShellError(code: 1, stderr: "No local clone of \(repo) is set")
        }
        let path = MyPRAction.newCheckoutPath(of: branch, repo: repo, repoFolder: folder,
            nextToClone: UserDefaults.standard.bool(forKey: TerminalApp.Worktree.nextToCloneKey))
        _ = try await sh(MyPRAction.makeCheckoutScript(branch: branch, repoFolder: folder, path: path))
        return path
    }
}
