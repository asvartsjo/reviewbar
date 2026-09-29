import XCTest
@testable import ReviewBar

final class RepoListTests: XCTestCase {
    func testAcceptsOwnerSlashRepo() {
        XCTAssertEqual(RepoList.normalize("Teachiq/web-platform"), "Teachiq/web-platform")
        XCTAssertEqual(RepoList.normalize("  asvartsjo/reviewbar \n"), "asvartsjo/reviewbar")
        XCTAssertEqual(RepoList.normalize("project/my.repo_name-2"), "project/my.repo_name-2")
    }

    func testAcceptsGitHubURLs() {
        XCTAssertEqual(RepoList.normalize("https://github.com/asvartsjo/reviewbar"), "asvartsjo/reviewbar")
        XCTAssertEqual(RepoList.normalize("https://www.github.com/asvartsjo/reviewbar/"), "asvartsjo/reviewbar")
        XCTAssertEqual(RepoList.normalize("github.com/asvartsjo/reviewbar/pull/12"), "asvartsjo/reviewbar")
        XCTAssertEqual(RepoList.normalize("https://github.com/asvartsjo/reviewbar.git"), "asvartsjo/reviewbar")
        XCTAssertEqual(RepoList.normalize("git@github.com:asvartsjo/reviewbar.git"), "asvartsjo/reviewbar")
    }

    func testRejectsNonRepos() {
        XCTAssertNil(RepoList.normalize("reviewbar"))
        XCTAssertNil(RepoList.normalize(""))
        XCTAssertNil(RepoList.normalize("owner/"))
        XCTAssertNil(RepoList.normalize("-bad/repo"))
        XCTAssertNil(RepoList.normalize("owner/repo;rm -rf"))
        XCTAssertNil(RepoList.normalize("owner name/repo"))
    }
}

final class RepoFolderTests: XCTestCase {
    func testRemotesMatch() {
        let remotes = "origin\tgit@github.com:Teachiq/gauss.git (fetch)\norigin\tgit@github.com:Teachiq/gauss.git (push)\n"
        XCTAssertTrue(RepoList.remotesMatch(remotes, repo: "teachiq/Gauss"))
        XCTAssertFalse(RepoList.remotesMatch(remotes, repo: "Teachiq/exam"))
        XCTAssertFalse(RepoList.remotesMatch("", repo: "Teachiq/gauss"))
    }

    func testWorktreeScriptLeavesTheCloneAlone() {
        let wt = TerminalApp.Worktree(repoFolder: "/Users/me/it's/gauss", path: "/wt/pr-7", number: 7)
        let s = wt.script
        XCTAssertTrue(s.contains(#"git -C '/Users/me/it'\''s/gauss' fetch --quiet origin +pull/7/head:refs/reviewbar/pr-7"#))
        XCTAssertTrue(s.contains("worktree add --quiet --detach '/wt/pr-7' refs/reviewbar/pr-7"))
        XCTAssertTrue(s.contains("checkout --quiet --detach refs/reviewbar/pr-7"))
        XCTAssertFalse(s.contains("checkout -b"))
    }

    func testLauncherRunsWorktreeBeforeAgent() {
        let wt = TerminalApp.Worktree(repoFolder: "/r", path: "/wt", number: 1)
        let s = TerminalApp.launcherScript(claude: "claude", promptFile: "/p", path: "", checkout: wt)
        let a = s.range(of: "worktree add")!, b = s.range(of: #"claude "$prompt""#)!
        XCTAssertLessThan(a.lowerBound, b.lowerBound)
    }
}

final class RepoDetectTests: XCTestCase {
    func testGitConfigMatch() {
        let config = "[core]\n\tbare = false\n[remote \"origin\"]\n\turl = git@github.com:Teachiq/gauss.git\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n"
        XCTAssertTrue(RepoList.configMatches(config, repo: "Teachiq/gauss"))
        XCTAssertFalse(RepoList.configMatches(config, repo: "Teachiq/exam"))
    }
}
