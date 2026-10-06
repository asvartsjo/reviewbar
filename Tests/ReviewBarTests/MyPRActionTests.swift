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
        let repo = root.appendingPathComponent("gauss").path, fix = root.appendingPathComponent("gauss-fix").path
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
}
