import Foundation

/// Your own worktrees (a branch checked out, not ReviewBar's `pr-<N>`) whose PR is merged or
/// closed. Only listed: ReviewBar removes nothing but the worktrees it made itself.
enum Cleanup {
    struct Candidate: Equatable, Identifiable {
        let repo: String
        /// The local clone, so the command works from any folder.
        let repoFolder: String
        let path: String
        let branch: String
        let prNumber: Int
        /// `MERGED` or `CLOSED`.
        let state: String
        var id: String { path }

        /// Without `--force`, so git refuses when the worktree has local changes. The branch is kept.
        var removeCommand: String { "git -C \(q(repoFolder)) worktree remove \(q(path))" }
    }

    /// A worktree on a branch, with `refs/heads/` dropped.
    struct BranchWorktree: Equatable {
        let path: String
        let branch: String
    }

    /// The latest PR whose head is a branch.
    struct LatestPR: Equatable {
        let number: Int
        let state: String
        let author: String?
    }

    /// Worktrees with a branch checked out, except the clone itself. ReviewBar's `pr-<N>` worktrees
    /// are detached, so they never match. Pure, for tests.
    static func branchWorktrees(_ listed: [TerminalApp.Worktree.Listed], repoFolder: String) -> [BranchWorktree] {
        func real(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
        let clone = real(repoFolder)
        return listed.compactMap { w in
            guard !w.detached, let ref = w.branch, ref.hasPrefix("refs/heads/"), real(w.path) != clone else { return nil }
            return BranchWorktree(path: w.path, branch: String(ref.dropFirst("refs/heads/".count)))
        }
    }

    /// One read-only GraphQL query: who I am, the repo's default branch, and the newest PR from each
    /// branch (aliases b0, b1… in `branches` order). Nil for a malformed repo name. Pure, for tests.
    static func query(repo: String, branches: [String]) -> String? {
        let parts = repo.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return nil }
        func lit(_ s: String) -> String { String(decoding: (try? JSONEncoder().encode(s)) ?? Data("\"\"".utf8), as: UTF8.self) }
        let prs = branches.enumerated().map { i, b in
            "b\(i): pullRequests(headRefName: \(lit(b)), first: 1, orderBy: {field: CREATED_AT, direction: DESC}) "
                + "{ nodes { number state author { login } } }"
        }.joined(separator: " ")
        return "query { viewer { login } repository(owner: \(lit(parts[0])), name: \(lit(parts[1]))) "
            + "{ defaultBranchRef { name } \(prs) } }"
    }

    /// The `query` response → my login, the default branch, and the newest PR per branch. Branches
    /// with no PR are left out; nil when it doesn't decode. Pure, for tests.
    static func parse(_ json: Data, branches: [String]) -> (viewer: String, defaultBranch: String?, latest: [String: LatestPR])? {
        guard let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
              let data = root["data"] as? [String: Any],
              let viewer = (data["viewer"] as? [String: Any])?["login"] as? String,
              let repo = data["repository"] as? [String: Any] else { return nil }
        var latest: [String: LatestPR] = [:]
        for (i, branch) in branches.enumerated() {
            guard let node = ((repo["b\(i)"] as? [String: Any])?["nodes"] as? [[String: Any]])?.first,
                  let number = node["number"] as? Int, let state = node["state"] as? String else { continue }
            latest[branch] = LatestPR(number: number, state: state, author: (node["author"] as? [String: Any])?["login"] as? String)
        }
        return (viewer, (repo["defaultBranchRef"] as? [String: Any])?["name"] as? String, latest)
    }

    /// The worktrees that can go: the newest PR from its branch is mine and merged or closed. A
    /// branch with no PR, a newer open PR, someone else's PR (a fork's branch of the same name), or
    /// the default branch (release PRs come from it) never counts. Pure, for tests.
    static func candidates(repo: String, repoFolder: String, worktrees: [BranchWorktree], viewer: String,
                           defaultBranch: String?, latest: [String: LatestPR]) -> [Candidate] {
        worktrees.compactMap { w in
            guard w.branch != defaultBranch, let pr = latest[w.branch], pr.state != "OPEN",
                  pr.author?.lowercased() == viewer.lowercased() else { return nil }
            return Candidate(repo: repo, repoFolder: repoFolder, path: w.path, branch: w.branch,
                             prNumber: pr.number, state: pr.state)
        }
    }
}

extension Backend {
    /// Your worktrees in `repos` that can go (`Cleanup.candidates`). Read only: `git worktree list`
    /// and one GraphQL query per repo with branch worktrees. Best effort: a repo that fails is left out.
    static func cleanupCandidates(repos: [String]) async -> [Cleanup.Candidate] {
        var found: [Cleanup.Candidate] = []
        for repo in repos {
            guard let folder = RepoList.folder(for: repo),
                  let list = try? await sh("git -C \(q(folder)) worktree list --porcelain") else { continue }
            let worktrees = Cleanup.branchWorktrees(TerminalApp.Worktree.parseList(list), repoFolder: folder)
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            let branches = worktrees.map(\.branch)
            guard !worktrees.isEmpty, let query = Cleanup.query(repo: repo, branches: branches),
                  let out = try? await sh("gh api graphql -f query=\(q(query))"),
                  let parsed = Cleanup.parse(Data(out.utf8), branches: branches) else { continue }
            found += Cleanup.candidates(repo: repo, repoFolder: folder, worktrees: worktrees, viewer: parsed.viewer,
                                        defaultBranch: parsed.defaultBranch, latest: parsed.latest)
        }
        return found
    }
}
