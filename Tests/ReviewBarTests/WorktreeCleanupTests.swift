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

    // MARK: Leaving a worktree a process works in

    @Test func parsesWorkingDirectories() {
        let lsof = "p412\nfcwd\nn/Users/me/TEACHIQ/gauss\np977\nfcwd\nn/Users/me/TEACHIQ/gauss-worktrees/pr-7/app\n"
        #expect(Worktree.parseCwds(lsof) == ["/Users/me/TEACHIQ/gauss", "/Users/me/TEACHIQ/gauss-worktrees/pr-7/app"])
        #expect(Worktree.parseCwds("").isEmpty)
    }

    @Test func aWorktreeIsInUseFromItsFolderOrBelow() {
        let beside = "/Users/me/TEACHIQ/gauss-worktrees"
        let worktrees = [7, 49, 50, 51].map { Worktree.forPR($0, repo: "o/gauss", repoFolder: clone, nextToClone: true) }
        let busy = Worktree.inUse(worktrees, cwds: ["\(beside)/pr-7",           // the folder itself
                                                    "\(beside)/pr-50/app/src",  // below it
                                                    "\(beside)/pr-4962",        // pr-49 is only a prefix
                                                    "\(beside)/pr-51x"])
        #expect(busy == ["\(beside)/pr-7", "\(beside)/pr-50"])
    }

    @Test func aWorktreeReachedThroughASymlinkIsInUse() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rb-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real/pr-7"), link = root.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("real"))
        let w = Worktree(repoFolder: clone, path: link.appendingPathComponent("pr-7").path, number: 7)
        #expect(Worktree.inUse([w], cwds: [real.resolvingSymlinksInPath().path]) == [w.path])
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
        _ = try? await sh(w.removeScript(finalHead: finalHead))
        let refGone = (try? await sh("git -C \(q(w.repoFolder)) rev-parse --verify --quiet \(w.ref)")) == nil
        let dirGone = !FileManager.default.fileExists(atPath: w.path)
        #expect(refGone == dirGone)
        return dirGone
    }

    private func head(_ folder: String) async throws -> String {
        try await sh("git -C \(q(folder)) rev-parse HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// `git pull origin main` to fix conflicts, then a relaunch back to the PR head: the merge
    /// commit's reflog entry starts with `pull`.
    @Test func keepsACommitAPullMade() async throws {
        let git = "git -c user.name=t -c user.email=t@t"
        let t = try await makeWorktree("""
            a=$(\(git) commit-tree -m a -p HEAD 'HEAD^{tree}') && b=$(\(git) commit-tree -m b -p HEAD 'HEAD^{tree}')
            git update-ref refs/heads/main-ish $b && git checkout -q --detach $a
            \(git) pull -q --no-rebase --no-edit . main-ish && git checkout -q --detach refs/reviewbar/pr-7
            """)
        defer { try? FileManager.default.removeItem(at: t.root) }
        #expect(await !remove(t.worktree, finalHead: t.head))
    }

    @Test func keepsAWorktreeWithoutAReflog() async throws {
        let t = try await makeWorktree(#"rm "$(git rev-parse --git-dir)/logs/HEAD""#)
        defer { try? FileManager.default.removeItem(at: t.root) }
        #expect(await !remove(t.worktree, finalHead: t.head))
    }

    /// Both locations can hold PR 7 (the setting changed in between); they share one ref.
    @Test func theWorktreeInTheOtherLocationGoesToo() async throws {
        let t = try await makeWorktree()
        defer { try? FileManager.default.removeItem(at: t.root) }
        let other = Worktree(repoFolder: t.worktree.repoFolder, path: t.root.appendingPathComponent("support/pr-7").path,
                             number: 7)
        _ = try await sh("git -C \(q(other.repoFolder)) worktree add --quiet --detach \(q(other.path)) \(other.ref)")
        #expect(await remove(t.worktree, finalHead: t.head))
        #expect(await remove(other, finalHead: t.head))
    }

    // MARK: Relaunching

    /// The clone is its own `origin`, with the PR head at `refs/pull/7/head`.
    private func publish(_ t: (root: URL, worktree: Worktree, head: String), head: String) async throws {
        let repo = q(t.worktree.repoFolder)
        _ = try await sh("git -C \(repo) remote get-url origin >/dev/null 2>&1 || git -C \(repo) remote add origin \(repo); "
            + "git -C \(repo) update-ref refs/pull/7/head \(head)")
    }

    @Test func aRelaunchMovesACleanWorktreeToTheNewHead() async throws {
        let t = try await makeWorktree()
        defer { try? FileManager.default.removeItem(at: t.root) }
        _ = try await sh("git -C \(q(t.worktree.repoFolder)) -c user.name=t -c user.email=t@t commit -q --allow-empty -m next")
        let next = try await head(t.worktree.repoFolder)
        try await publish(t, head: next)
        _ = try await sh(t.worktree.script)
        #expect(try await head(t.worktree.path) == next)
    }

    @Test func aRelaunchKeepsEditedFiles() async throws {
        let t = try await makeWorktree("print more >> .gitignore")
        defer { try? FileManager.default.removeItem(at: t.root) }
        _ = try await sh("git -C \(q(t.worktree.repoFolder)) -c user.name=t -c user.email=t@t commit -q --allow-empty -m next")
        try await publish(t, head: try await head(t.worktree.repoFolder))
        let out = try await sh(t.worktree.script)
        #expect(try await head(t.worktree.path) == t.head)
        #expect(out.contains("it has local changes"))
    }

    @Test func aRelaunchKeepsLocalCommits() async throws {
        let t = try await makeWorktree("print y > fix.txt && git add fix.txt && git -c user.name=t -c user.email=t@t commit -qm fix")
        defer { try? FileManager.default.removeItem(at: t.root) }
        try await publish(t, head: t.worktree.ref)
        let out = try await sh(t.worktree.script)
        #expect(try await head(t.worktree.path) == t.head)
        #expect(out.contains("commits the PR doesn't have yet"))
    }
}
