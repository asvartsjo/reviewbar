import Foundation
import Testing
@testable import ReviewBar

struct MyPRActionTests {
    private func mine(draft: Bool = false, decision: String? = "REVIEW_REQUIRED", threads: Int = 0,
                      checks: String? = "SUCCESS", mergeable: String? = "MERGEABLE") -> FeedbackPR {
        let pr = PR(number: 7, title: "Mine", url: "https://github.com/o/r/pull/7", isDraft: draft,
                    updatedAt: "2026-10-04T00:00:00Z", repository: .init(nameWithOwner: "o/r"), author: .init(login: "me"))
        return FeedbackPR(pr: pr, decision: decision, threads: threads, reviews: 0, comments: 0,
                          latestAt: "", latestBy: "", checks: checks, mergeable: mergeable)
    }

    private func action(_ f: FeedbackPR, feedback: String? = "/pr-feedback", merge: String? = "can I merge?") -> MyPRAction? {
        MyPRAction.for(f, feedbackCommand: feedback, mergeCommand: merge)
    }

    @Test func eachMoveGetsItsCommand() {
        #expect(action(mine(threads: 1)) == .feedback(command: "/pr-feedback"))
        #expect(action(mine(checks: "FAILURE")) == .feedback(command: "/pr-feedback"))
        #expect(action(mine(decision: "APPROVED")) == .merge(command: "can I merge?"))
        #expect(action(mine(mergeable: "CONFLICTING")) == nil)
        #expect(action(mine(draft: true)) == nil)
        #expect(action(mine(checks: "PENDING")) == nil)
        #expect(action(mine()) == nil)
    }

    @Test func emptyCommandMeansNoAction() {
        #expect(action(mine(threads: 1), feedback: nil) == nil)
        #expect(action(mine(decision: "APPROVED"), merge: nil) == nil)
    }

    /// Real `git worktree list` output: the clone on main, a worktree on the PR branch, and a
    /// detached review worktree. Only the branch's checkout is picked, never a detached one.
    @Test func findsTheCheckoutOfTheBranchInRealGitOutput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rb-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("storefront").path, fix = root.appendingPathComponent("storefront-fix").path
        let list = try await sh("""
            set -e
            mkdir -p \(q(root.path)) && git init -q -b main \(q(repo)) && cd \(q(repo))
            git -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
            git worktree add --quiet -b atanas/fix \(q(fix))
            git worktree add --quiet --detach \(q(root.appendingPathComponent("pr-7").path))
            git worktree list --porcelain
            """)
        let listed = TerminalApp.Worktree.parseList(list)
        func real(_ p: String?) -> String? { p.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } }
        #expect(real(MyPRAction.checkout(of: "atanas/fix", in: listed)) == real(fix))
        #expect(real(MyPRAction.checkout(of: "main", in: listed)) == real(repo))
        #expect(MyPRAction.checkout(of: "atanas/other", in: listed) == nil)
        #expect(MyPRAction.checkout(of: "atanas", in: listed) == nil)
    }

    /// A fork's PR from `main` must not land in the clone's own `main`, which tracks origin.
    @Test func onlyTheForksBranchCountsForAForkPR() {
        #expect(!MyPRAction.isForkBranch(remote: "origin", merge: "refs/heads/main", number: 7))
        #expect(!MyPRAction.isForkBranch(remote: nil, merge: nil, number: 7))           // no upstream: a local branch
        #expect(MyPRAction.isForkBranch(remote: "origin", merge: "refs/pull/7/head", number: 7))   // gh pr checkout
        #expect(!MyPRAction.isForkBranch(remote: "origin", merge: "refs/pull/8/head", number: 7))
        #expect(MyPRAction.isForkBranch(remote: "carol", merge: "refs/heads/main", number: 7))     // the fork's remote
        #expect(MyPRAction.isForkBranch(remote: "https://github.com/carol/storefront.git", merge: "refs/heads/main",
                                        number: 7))
    }

    @Test func newCheckoutGoesBesideThePRWorktrees() {
        let clone = "/Users/me/code/storefront"
        #expect(MyPRAction.newCheckoutPath(of: "atanas/fix", repo: "acme/storefront", repoFolder: clone, nextToClone: true)
                == "/Users/me/code/storefront-worktrees/atanas-fix")
        let pr = TerminalApp.Worktree.forPR(7, repo: "acme/storefront", repoFolder: clone, nextToClone: false).path
        let branch = MyPRAction.newCheckoutPath(of: "atanas/fix", repo: "acme/storefront", repoFolder: clone, nextToClone: false)
        #expect((branch as NSString).deletingLastPathComponent == (pr as NSString).deletingLastPathComponent)
        #expect((branch as NSString).lastPathComponent == "atanas-fix")
    }

    /// Real git: a branch only on origin becomes a local branch tracking it, a local-only branch is
    /// checked out as it is, a local branch behind origin is fast-forwarded, and a worktree whose folder
    /// was deleted neither matches nor blocks a new one.
    @Test func makesACheckoutOfTheBranchInRealGit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rb-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        func at(_ name: String) -> String { root.appendingPathComponent(name).path }
        _ = try await sh("""
            set -e
            mkdir -p \(q(root.path)) && git init -q -b main \(q(at("origin"))) && cd \(q(at("origin")))
            git -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
            git branch atanas/remote-only
            git branch atanas/behind
            git clone -q \(q(at("origin"))) \(q(at("storefront")))
            git -C \(q(at("storefront"))) branch atanas/local-only
            git -C \(q(at("storefront"))) branch -q atanas/behind origin/atanas/behind
            git switch -q atanas/behind
            git -c user.name=t -c user.email=t@t commit -q --allow-empty -m ahead
            git switch -q main
            """)
        func make(_ branch: String, _ path: String) async throws -> String {
            try await sh(MyPRAction.makeCheckoutScript(branch: branch, repoFolder: at("storefront"), path: path)
                + " || exit 1\ngit -C \(q(path)) rev-parse --abbrev-ref HEAD\n"
                + "git -C \(q(path)) rev-parse --abbrev-ref @{u} 2>/dev/null; true")
        }
        func listed() async throws -> [TerminalApp.Worktree.Listed] {
            TerminalApp.Worktree.parseList(try await sh("git -C \(q(at("storefront"))) worktree list --porcelain"))
        }

        let remote = try await make("atanas/remote-only", at("wt/atanas-remote-only"))
        #expect(remote.contains("atanas/remote-only\norigin/atanas/remote-only"))
        let local = try await make("atanas/local-only", at("wt/atanas-local-only"))
        #expect(local.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("atanas/local-only"))
        #expect(MyPRAction.checkout(of: "atanas/local-only", in: try await listed()) != nil)

        _ = try await make("atanas/behind", at("wt/atanas-behind"))
        let heads = try await sh("git -C \(q(at("wt/atanas-behind"))) rev-parse HEAD; git -C \(q(at("origin"))) rev-parse atanas/behind")
        let shas = heads.split(separator: "\n")
        #expect(shas.count == 2 && shas[0] == shas[1])

        try FileManager.default.removeItem(atPath: at("wt/atanas-local-only"))
        #expect(MyPRAction.checkout(of: "atanas/local-only", in: try await listed()) == nil)
        _ = try await make("atanas/local-only", at("wt2/atanas-local-only"))
        func real(_ p: String?) -> String? { p.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } }
        #expect(real(MyPRAction.checkout(of: "atanas/local-only", in: try await listed())) == real(at("wt2/atanas-local-only")))

        await #expect(throws: ShellError.self) { try await make("atanas/nowhere", at("wt/atanas-nowhere")) }
    }
}
