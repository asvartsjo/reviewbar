import Foundation
import Testing
@testable import ReviewBar

struct CleanupTests {
    typealias Listed = TerminalApp.Worktree.Listed

    private let clone = "/Users/me/code/storefront"
    private let beside = "/Users/me/code/storefront-worktrees"

    @Test func onlyYourBranchWorktreesCount() {
        let listed: [Listed] = [
            .init(path: clone, detached: false, branch: "refs/heads/development"),   // the clone
            .init(path: "\(beside)/wt1", detached: false, branch: "refs/heads/me/a", head: "abc"),
            .init(path: "\(clone)/.claude/worktrees/fix", detached: false, branch: "refs/heads/fix"),
            .init(path: "\(beside)/pr-7", detached: true),                            // ReviewBar's
            .init(path: "\(beside)/wt2", detached: true),                             // detached, no branch
        ]
        #expect(Cleanup.branchWorktrees(listed, repoFolder: clone) == [
            .init(path: "\(beside)/wt1", branch: "me/a", head: "abc"),
            .init(path: "\(clone)/.claude/worktrees/fix", branch: "fix"),
        ])
    }

    @Test func queryAsksForTheNewestPRPerBranch() throws {
        let query = try #require(Cleanup.query(repo: "o/storefront", branches: ["me/a", "x\"y"]))
        #expect(query.contains(#"repository(owner: "o", name: "storefront")"#))
        #expect(query.contains(#"b0: pullRequests(headRefName: "me\/a", first: 1"#))
        #expect(query.contains(#"b1: pullRequests(headRefName: "x\"y""#))
        #expect(query.contains("viewer { login }") && query.contains("defaultBranchRef { name }"))
        #expect(query.contains("headRefOid") && query.contains("isCrossRepository"))
        #expect(Cleanup.query(repo: "nope", branches: ["a"]) == nil)
    }

    @Test func parsesTheResponse() throws {
        let json = #"{"data": {"viewer": {"login": "me"}, "repository": {"defaultBranchRef": {"name": "development"},"#
            + #" "b0": {"nodes": [{"number": 7, "state": "MERGED", "headRefOid": "abc", "author": {"login": "me"}}]},"#
            + #" "b1": {"nodes": []}, "b2": {"nodes": [{"number": 9, "state": "CLOSED", "author": null}]},"#
            + #" "b3": {"nodes": [{"number": 11, "state": "MERGED", "isCrossRepository": true, "author": {"login": "me"}}]}}}}"#
        let parsed = try #require(Cleanup.parse(Data(json.utf8), branches: ["a", "b", "c", "d"]))
        #expect(parsed.viewer == "me")
        #expect(parsed.defaultBranch == "development")
        #expect(parsed.latest == ["a": .init(number: 7, state: "MERGED", author: "me", headRefOid: "abc"),
                                  "c": .init(number: 9, state: "CLOSED", author: nil),
                                  "d": .init(number: 11, state: "MERGED", author: "me", crossRepo: true)])
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
            "merged": pr(1, "MERGED", "Me", head: "sha-merged"),
            "closed": pr(2, "CLOSED", "me", head: "sha-closed"),
            "open": pr(3, "OPEN", "me", head: "sha-open"),                 // reused branch, new PR open
            "theirs": pr(4, "MERGED", "someone", head: "sha-theirs"),          // a fork's branch of that name
            "forked": .init(number: 8, state: "MERGED", author: "me", headRefOid: "sha-forked", crossRepo: true),
            "development": pr(5, "MERGED", "me", head: "sha-development"), // a release PR
            "ghost": pr(6, "MERGED", nil, head: "sha-ghost"),                  // deleted account
            "moved": pr(7, "MERGED", "me", head: "older"),                 // reused branch, no PR yet
        ]
        let found = Cleanup.candidates(repo: "o/storefront", repoFolder: clone, worktrees: worktrees, viewer: "me",
                                       defaultBranch: "development", latest: latest)
        #expect(found.map(\.prNumber) == [1, 2])
        #expect(found.first?.removeCommand == "git -C '\(clone)' worktree remove '\(beside)/merged'")
    }
}
