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

    /// The worktree, or the clone itself, that has `branch` checked out. Git allows only one.
    /// Pure, for tests.
    static func checkout(of branch: String, in listed: [TerminalApp.Worktree.Listed]) -> String? {
        listed.first { $0.branch == "refs/heads/\(branch)" }?.path
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
}
