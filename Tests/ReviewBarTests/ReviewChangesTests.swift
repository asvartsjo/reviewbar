import Foundation
import Testing
@testable import ReviewBar

struct ReviewChangesTests {
    /// Shaped like the output of `gh api …/compare/A...B --jq <compareJQ>`.
    private func compareJSON(_ status: String, aheadBy: Int, commits: [(String, String)] = []) -> Data {
        let c = commits.map { #"{"sha": "\#($0.0)", "message": "\#($0.1)"}"# }.joined(separator: ",")
        return Data(#"{"status": "\#(status)", "ahead_by": \#(aheadBy), "commits": [\#(c)]}"#.utf8)
    }

    @Test func forwardMoveIsIncremental() throws {
        let info = try Backend.parseCompare(compareJSON("ahead", aheadBy: 2,
            commits: [("abc1234", "Fix bulk import invalidation"), ("def5678", "Add test")]))
        #expect(info.isIncremental)
        #expect(info.aheadBy == 2)
        #expect(info.commits.map(\.sha) == ["abc1234", "def5678"])
        #expect(info.commits.first?.message == "Fix bulk import invalidation")
    }

    /// After a rebase, A...B would also contain the base branch's changes: fall back.
    @Test func rebasedOrRewoundIsNotIncremental() throws {
        #expect(try !Backend.parseCompare(compareJSON("diverged", aheadBy: 3)).isIncremental)
        #expect(try !Backend.parseCompare(compareJSON("behind", aheadBy: 0)).isIncremental)
        #expect(try !Backend.parseCompare(compareJSON("identical", aheadBy: 0)).isIncremental)
    }

    @Test func commitSHAValidation() {
        #expect(Backend.isCommitSHA("abc1234"))
        #expect(Backend.isCommitSHA("0123456789abcdef0123456789abcdef01234567"))
        #expect(!Backend.isCommitSHA("abc12"))
        #expect(!Backend.isCommitSHA("ABC1234"))
        #expect(!Backend.isCommitSHA("abc1234; rm -rf ~"))
        #expect(!Backend.isCommitSHA("main"))
    }

    /// Reviews saved before model labels and since-reviews existed must still load.
    @Test func oldSavedReviewsStillDecode() throws {
        let json = """
        [{"pr": {"number": 1, "title": "t", "url": "u", "isDraft": false, "updatedAt": "2026-09-01T00:00:00Z",
                 "repository": {"nameWithOwner": "o/r"}, "author": {"login": "a"}},
          "text": "notes", "date": "2026-09-01T00:00:00Z"}]
        """
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let saved = try dec.decode([SavedReview].self, from: Data(json.utf8))
        #expect(saved.count == 1)
        #expect(saved[0].producedBy == nil)
        #expect(saved[0].sinceCommit == nil)
        #expect(saved[0].pr.headRefOid == nil)
    }
}
