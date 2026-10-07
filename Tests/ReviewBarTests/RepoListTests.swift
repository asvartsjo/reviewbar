import Testing
@testable import ReviewBar

struct RepoListTests {
    @Test func acceptsOwnerSlashRepo() {
        #expect(RepoList.normalize("acme/web-platform") == "acme/web-platform")
        #expect(RepoList.normalize("  asvartsjo/reviewbar \n") == "asvartsjo/reviewbar")
        #expect(RepoList.normalize("project/my.repo_name-2") == "project/my.repo_name-2")
    }

    @Test func acceptsGitHubURLs() {
        #expect(RepoList.normalize("https://github.com/asvartsjo/reviewbar") == "asvartsjo/reviewbar")
        #expect(RepoList.normalize("https://www.github.com/asvartsjo/reviewbar/") == "asvartsjo/reviewbar")
        #expect(RepoList.normalize("github.com/asvartsjo/reviewbar/pull/12") == "asvartsjo/reviewbar")
        #expect(RepoList.normalize("https://github.com/asvartsjo/reviewbar.git") == "asvartsjo/reviewbar")
        #expect(RepoList.normalize("git@github.com:asvartsjo/reviewbar.git") == "asvartsjo/reviewbar")
    }

    @Test func rejectsNonRepos() {
        #expect(RepoList.normalize("reviewbar") == nil)
        #expect(RepoList.normalize("") == nil)
        #expect(RepoList.normalize("owner/") == nil)
        #expect(RepoList.normalize("-bad/repo") == nil)
        #expect(RepoList.normalize("owner/repo;rm -rf") == nil)
        #expect(RepoList.normalize("owner name/repo") == nil)
    }
}

struct RepoFolderTests {
    @Test func remotesMatch() {
        let remotes = "origin\tgit@github.com:acme/storefront.git (fetch)\norigin\tgit@github.com:acme/storefront.git (push)\n"
        #expect(RepoList.remotesMatch(remotes, repo: "ACME/Storefront"))
        #expect(!RepoList.remotesMatch(remotes, repo: "acme/api"))
        #expect(!RepoList.remotesMatch("", repo: "acme/storefront"))
    }

    @Test func worktreeScriptLeavesTheCloneAlone() {
        let wt = TerminalApp.Worktree(repoFolder: "/Users/me/it's/storefront", path: "/wt/pr-7", number: 7)
        let s = wt.script
        #expect(s.contains(#"git -C '/Users/me/it'\''s/storefront' fetch --quiet origin +pull/7/head:refs/reviewbar/pr-7"#))
        #expect(s.contains("worktree add --quiet --detach '/wt/pr-7' refs/reviewbar/pr-7"))
        #expect(s.contains("checkout --quiet --detach refs/reviewbar/pr-7"))
        #expect(!s.contains("checkout -b"))
    }

    @Test func worktreePaths() {
        let pr = PR(number: 7, title: "t", url: "https://github.com/acme/storefront/pull/7", isDraft: false,
                    updatedAt: "2026-09-01T00:00:00Z", repository: .init(nameWithOwner: "acme/storefront"),
                    author: .init(login: "a"))
        let beside = TerminalApp.Worktree.forPR(pr, repoFolder: "/Users/me/code/storefront/", nextToClone: true)
        #expect(beside.path == "/Users/me/code/storefront-worktrees/pr-7")
        #expect(beside.repoFolder == "/Users/me/code/storefront/")
        let support = TerminalApp.Worktree.forPR(pr, repoFolder: "/Users/me/code/storefront", nextToClone: false)
        #expect(support.path.hasSuffix("/ReviewBar/worktrees/acme-storefront/pr-7"))
    }

    @Test func launcherRunsWorktreeBeforeAgent() throws {
        let wt = TerminalApp.Worktree(repoFolder: "/r", path: "/wt", number: 1)
        let s = TerminalApp.launcherScript(claude: "claude", promptFile: "/p", path: "", checkout: wt)
        let a = try #require(s.range(of: "worktree add")), b = try #require(s.range(of: #"claude "$prompt""#))
        #expect(a.lowerBound < b.lowerBound)
    }
}

struct RepoDetectTests {
    @Test func gitConfigMatch() {
        let config = "[core]\n\tbare = false\n[remote \"origin\"]\n\turl = git@github.com:acme/storefront.git\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n"
        #expect(RepoList.configMatches(config, repo: "acme/storefront"))
        #expect(!RepoList.configMatches(config, repo: "acme/api"))
    }
}
