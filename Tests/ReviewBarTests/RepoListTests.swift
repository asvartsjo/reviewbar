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
