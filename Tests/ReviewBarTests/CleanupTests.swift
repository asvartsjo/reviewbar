import Foundation
import Testing
@testable import ReviewBar

struct CleanupTests {
    typealias Listed = TerminalApp.Worktree.Listed

    private let clone = "/Users/me/TEACHIQ/gauss"
    private let beside = "/Users/me/TEACHIQ/gauss-worktrees"

    @Test func onlyYourBranchWorktreesCount() {
        let listed: [Listed] = [
            .init(path: clone, detached: false, branch: "refs/heads/development"),   // the clone
            .init(path: "\(beside)/wt1", detached: false, branch: "refs/heads/atanas/a"),
            .init(path: "\(clone)/.claude/worktrees/fix", detached: false, branch: "refs/heads/fix"),
            .init(path: "\(beside)/pr-7", detached: true),                            // ReviewBar's
            .init(path: "\(beside)/wt2", detached: true),                             // detached, no branch
        ]
        #expect(Cleanup.branchWorktrees(listed, repoFolder: clone) == [
            .init(path: "\(beside)/wt1", branch: "atanas/a"),
            .init(path: "\(clone)/.claude/worktrees/fix", branch: "fix"),
        ])
    }

    @Test func queryAsksForTheNewestPRPerBranch() throws {
        let query = try #require(Cleanup.query(repo: "o/gauss", branches: ["atanas/a", "x\"y"]))
        #expect(query.contains(#"repository(owner: "o", name: "gauss")"#))
        #expect(query.contains(#"b0: pullRequests(headRefName: "atanas\/a", first: 1"#))
        #expect(query.contains(#"b1: pullRequests(headRefName: "x\"y""#))
        #expect(query.contains("viewer { login }") && query.contains("defaultBranchRef { name }"))
        #expect(Cleanup.query(repo: "nope", branches: ["a"]) == nil)
    }

    @Test func parsesTheResponse() throws {
        let json = #"{"data": {"viewer": {"login": "atanas"}, "repository": {"defaultBranchRef": {"name": "development"},"#
            + #" "b0": {"nodes": [{"number": 7, "state": "MERGED", "author": {"login": "atanas"}}]},"#
            + #" "b1": {"nodes": []}, "b2": {"nodes": [{"number": 9, "state": "CLOSED", "author": null}]}}}}"#
        let parsed = try #require(Cleanup.parse(Data(json.utf8), branches: ["a", "b", "c"]))
        #expect(parsed.viewer == "atanas")
        #expect(parsed.defaultBranch == "development")
        #expect(parsed.latest == ["a": .init(number: 7, state: "MERGED", author: "atanas"),
                                  "c": .init(number: 9, state: "CLOSED", author: nil)])
        #expect(Cleanup.parse(Data("oops".utf8), branches: ["a"]) == nil)
    }

    @Test func onlyMyMergedOrClosedPRsMakeACandidate() {
        let worktrees = ["merged", "closed", "open", "none", "theirs", "development", "ghost"]
            .map { Cleanup.BranchWorktree(path: "\(beside)/\($0)", branch: $0) }
        let latest: [String: Cleanup.LatestPR] = [
            "merged": .init(number: 1, state: "MERGED", author: "Atanas"),
            "closed": .init(number: 2, state: "CLOSED", author: "atanas"),
            "open": .init(number: 3, state: "OPEN", author: "atanas"),         // reused branch, new PR open
            "theirs": .init(number: 4, state: "MERGED", author: "someone"),    // a fork's branch of that name
            "development": .init(number: 5, state: "MERGED", author: "atanas"), // a release PR
            "ghost": .init(number: 6, state: "MERGED", author: nil),           // deleted account
        ]
        let found = Cleanup.candidates(repo: "o/gauss", repoFolder: clone, worktrees: worktrees, viewer: "atanas",
                                       defaultBranch: "development", latest: latest)
        #expect(found.map(\.prNumber) == [1, 2])
        #expect(found.first?.removeCommand == "git -C '\(clone)' worktree remove '\(beside)/merged'")
    }
}
