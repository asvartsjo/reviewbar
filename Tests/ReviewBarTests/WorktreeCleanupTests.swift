import Foundation
import Testing
@testable import ReviewBar

struct WorktreeCleanupTests {
    typealias Worktree = TerminalApp.Worktree

    // MARK: Which worktrees are ours

    private let clone = "/Users/me/TEACHIQ/gauss"

    private func porcelain(_ entries: [(String, String)]) -> String {
        entries.map { "worktree \($0.0)\nHEAD abc\n\($0.1)" }.joined(separator: "\n\n") + "\n"
    }

    @Test func parsesWorktreeList() {
        let list = Worktree.parseList(porcelain([(clone, "branch refs/heads/development"),
                                                 ("/Users/me/TEACHIQ/gauss-worktrees/pr-7", "detached")]))
        #expect(list == [.init(path: clone, detached: false),
                         .init(path: "/Users/me/TEACHIQ/gauss-worktrees/pr-7", detached: true)])
    }

    @Test func onlyDetachedPRFoldersWhereReviewBarPutsThemAreOurs() {
        let beside = "/Users/me/TEACHIQ/gauss-worktrees"
        let support = Worktree.forPR(9, repo: "o/gauss", repoFolder: clone, nextToClone: false).path
        let list = Worktree.parseList(porcelain([
            (clone, "branch refs/heads/development"),
            ("\(beside)/pr-7", "detached"),                    // ours, next to the clone
            (support, "detached"),                             // ours, under Application Support
            ("\(beside)/pr-8", "branch refs/heads/atanas/x"),  // right name, but a branch is checked out
            ("\(beside)/wt1", "detached"),                     // your own worktree
            ("\(beside)/grading-lock-order", "detached"),
            ("/Users/me/elsewhere/pr-10", "detached"),         // pr-N, but not where ReviewBar puts it
            ("\(beside)/pr-x", "detached"),
        ]))
        #expect(Worktree.ours(list, repo: "o/gauss", repoFolder: clone).map(\.number) == [7, 9])
    }

    @Test func parsesPRStates() {
        let json = #"{"data": {"repository": {"p7": {"state": "MERGED", "headRefOid": "abc"}, "p8": null,"#
            + #" "p9": {"state": "OPEN", "headRefOid": null}}}}"#
        #expect(Backend.parsePRStates(Data(json.utf8))
                == [7: .init(state: "MERGED", headRefOid: "abc"), 9: .init(state: "OPEN", headRefOid: nil)])
        #expect(Backend.parsePRStates(Data("oops".utf8)) == nil)
    }

    // MARK: Removing one, with real git

    /// A clone in a temporary folder with ReviewBar's worktree for PR 7 beside it, detached at
    /// `refs/reviewbar/pr-7`. `setup` runs inside the worktree. Returns the worktree and its HEAD.
    private func makeWorktree(_ setup: String = "") async throws -> (root: URL, worktree: Worktree, head: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rb-\(UUID().uuidString.prefix(8))")
        let repo = root.appendingPathComponent("repo").path
        let w = Worktree.forPR(7, repo: "o/repo", repoFolder: repo, nextToClone: true)
        let git = "git -c user.name=t -c user.email=t@t"
        let out = try await sh("""
            set -e
            mkdir -p \(q(root.path)) && git init -q \(q(repo)) && cd \(q(repo))
            print /vendor > .gitignore && git add .gitignore && \(git) commit -qm init
            git update-ref \(w.ref) HEAD
            git worktree add --quiet --detach \(q(w.path)) \(w.ref)
            cd \(q(w.path))
            \(setup)
            git rev-parse HEAD
            """)
        return (root, w, out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Runs `removeScript` and says whether the worktree went. Its ref goes with it, or neither does.
    private func remove(_ w: Worktree, finalHead: String?) async -> Bool {
        let refGone = (try? await sh(w.removeScript(finalHead: finalHead)
            + "\ngit -C \(q(w.repoFolder)) rev-parse --verify --quiet \(w.ref) || print gone")) == "gone\n"
        let dirGone = !FileManager.default.fileExists(atPath: w.path)
        #expect(refGone == dirGone)
        return dirGone
    }

    @Test func removesACleanWorktreeAndItsRef() async throws {
        let t = try await makeWorktree()
        defer { try? FileManager.default.removeItem(at: t.root) }
        #expect(await remove(t.worktree, finalHead: nil))
    }

    @Test func ignoredFilesSuchAsVendorDontCount() async throws {
        let t = try await makeWorktree("mkdir vendor && print x > vendor/big")
        defer { try? FileManager.default.removeItem(at: t.root) }
        #expect(await remove(t.worktree, finalHead: nil))
    }

    @Test func keepsUntrackedAndEditedFiles() async throws {
        for setup in ["print x > notes.md", "print more >> .gitignore",
                      "git config status.showUntrackedFiles no && print x > notes.md"] {
            let t = try await makeWorktree(setup)
            defer { try? FileManager.default.removeItem(at: t.root) }
            #expect(await !remove(t.worktree, finalHead: nil), "\(setup)")
        }
    }

    @Test func keepsAnUnpushedCommitButNotAPushedOne() async throws {
        let commit = "print y > fix.txt && git add fix.txt && git -c user.name=t -c user.email=t@t commit -qm fix"
        let unpushed = try await makeWorktree(commit)
        defer { try? FileManager.default.removeItem(at: unpushed.root) }
        #expect(await !remove(unpushed.worktree, finalHead: "0000000"))

        // The PR's last head on GitHub is this commit: it was pushed.
        #expect(await remove(unpushed.worktree, finalHead: unpushed.head))
    }

    @Test func keepsACommitARelaunchMovedAwayFrom() async throws {
        let commit = "print y > fix.txt && git add fix.txt && git -c user.name=t -c user.email=t@t commit -qm fix"
        let t = try await makeWorktree(commit + " && git checkout -q --detach HEAD~1")
        defer { try? FileManager.default.removeItem(at: t.root) }
        #expect(await !remove(t.worktree, finalHead: t.head))
    }
}
