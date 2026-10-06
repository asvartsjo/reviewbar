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
            .init(path: "\(beside)/wt1", detached: false, branch: "refs/heads/atanas/a", head: "abc"),
            .init(path: "\(clone)/.claude/worktrees/fix", detached: false, branch: "refs/heads/fix"),
            .init(path: "\(beside)/pr-7", detached: true),                            // ReviewBar's
            .init(path: "\(beside)/wt2", detached: true),                             // detached, no branch
        ]
        #expect(Cleanup.branchWorktrees(listed, repoFolder: clone) == [
            .init(path: "\(beside)/wt1", branch: "atanas/a", head: "abc"),
            .init(path: "\(clone)/.claude/worktrees/fix", branch: "fix"),
        ])
    }

    @Test func queryAsksForTheNewestPRPerBranch() throws {
        let query = try #require(Cleanup.query(repo: "o/gauss", branches: ["atanas/a", "x\"y"]))
        #expect(query.contains(#"repository(owner: "o", name: "gauss")"#))
        #expect(query.contains(#"b0: pullRequests(headRefName: "atanas\/a", first: 1"#))
        #expect(query.contains(#"b1: pullRequests(headRefName: "x\"y""#))
        #expect(query.contains("viewer { login }") && query.contains("defaultBranchRef { name }"))
        #expect(query.contains("headRefOid") && query.contains("isCrossRepository"))
        #expect(Cleanup.query(repo: "nope", branches: ["a"]) == nil)
    }

    @Test func parsesTheResponse() throws {
        let json = #"{"data": {"viewer": {"login": "atanas"}, "repository": {"defaultBranchRef": {"name": "development"},"#
            + #" "b0": {"nodes": [{"number": 7, "state": "MERGED", "headRefOid": "abc", "author": {"login": "atanas"}}]},"#
            + #" "b1": {"nodes": []}, "b2": {"nodes": [{"number": 9, "state": "CLOSED", "author": null}]},"#
            + #" "b3": {"nodes": [{"number": 11, "state": "MERGED", "isCrossRepository": true, "author": {"login": "atanas"}}]}}}}"#
        let parsed = try #require(Cleanup.parse(Data(json.utf8), branches: ["a", "b", "c", "d"]))
        #expect(parsed.viewer == "atanas")
        #expect(parsed.defaultBranch == "development")
        #expect(parsed.latest == ["a": .init(number: 7, state: "MERGED", author: "atanas", headRefOid: "abc"),
                                  "c": .init(number: 9, state: "CLOSED", author: nil),
                                  "d": .init(number: 11, state: "MERGED", author: "atanas", crossRepo: true)])
        #expect(Cleanup.parse(Data("oops".utf8), branches: ["a"]) == nil)
        let failed = #"{"data": null, "errors": [{"message": "Could not resolve to a Repository"}]}"#
        #expect(Cleanup.parse(Data(failed.utf8), branches: ["a"]) == nil)
    }

    @Test func onlyMyMergedOrClosedPRsMakeACandidate() {
        let worktrees = ["merged", "closed", "open", "none", "theirs", "forked", "development", "ghost", "moved"]
            .map { Cleanup.BranchWorktree(path: "\(beside)/\($0)", branch: $0, head: "sha-\($0)") }
        func pr(_ number: Int, _ state: String, _ author: String?, head: String) -> Cleanup.LatestPR {
            .init(number: number, state: state, author: author, headRefOid: head)
        }
        let latest: [String: Cleanup.LatestPR] = [
            "merged": pr(1, "MERGED", "Atanas", head: "sha-merged"),
            "closed": pr(2, "CLOSED", "atanas", head: "sha-closed"),
            "open": pr(3, "OPEN", "atanas", head: "sha-open"),                 // reused branch, new PR open
            "theirs": pr(4, "MERGED", "someone", head: "sha-theirs"),          // a fork's branch of that name
            "forked": .init(number: 8, state: "MERGED", author: "atanas", headRefOid: "sha-forked", crossRepo: true),
            "development": pr(5, "MERGED", "atanas", head: "sha-development"), // a release PR
            "ghost": pr(6, "MERGED", nil, head: "sha-ghost"),                  // deleted account
            "moved": pr(7, "MERGED", "atanas", head: "older"),                 // reused branch, no PR yet
        ]
        let found = Cleanup.candidates(repo: "o/gauss", repoFolder: clone, worktrees: worktrees, viewer: "atanas",
                                       defaultBranch: "development", latest: latest)
        #expect(found.map(\.prNumber) == [1, 2])
        #expect(found.first?.removeCommand == "git -C '\(clone)' worktree remove '\(beside)/merged'")
    }
}
