import XCTest
@testable import ReviewBar

final class ClaudeSettingsTests: XCTestCase {
    private let keys = [ClaudeSettings.reviewModelKey, ClaudeSettings.reviewEffortKey,
                        ClaudeSettings.quickModelKey, ClaudeSettings.quickEffortKey]
    private var saved: [String: Any] = [:]

    override func setUp() {
        for k in keys { saved[k] = UserDefaults.standard.object(forKey: k) }
        for k in keys { UserDefaults.standard.removeObject(forKey: k) }
    }

    override func tearDown() {
        for k in keys {
            if let v = saved[k] { UserDefaults.standard.set(v, forKey: k) }
            else { UserDefaults.standard.removeObject(forKey: k) }
        }
    }

    func testDefaults() {
        XCTAssertEqual(ClaudeSettings.review.model, "opus")
        XCTAssertEqual(ClaudeSettings.review.effort, "")
        XCTAssertEqual(ClaudeSettings.quick.model, "sonnet")
        XCTAssertEqual(ClaudeSettings.quick.effort, "low")
    }

    func testFlags() {
        XCTAssertEqual(ClaudeSettings.flags(("opus", "high")), " --model opus --effort high")
        XCTAssertEqual(ClaudeSettings.flags(("sonnet", "")), " --model sonnet")
        XCTAssertEqual(ClaudeSettings.flags(("", "")), "")
    }

    func testSameAsReviewUsesReviewModel() {
        UserDefaults.standard.set("haiku", forKey: ClaudeSettings.reviewModelKey)
        UserDefaults.standard.set(ClaudeSettings.sameAsReview, forKey: ClaudeSettings.quickModelKey)
        XCTAssertEqual(ClaudeSettings.quick.model, "haiku")
    }

    /// Only whitelisted values may reach the shell command line.
    func testUnknownValuesFallBackToDefaults() {
        UserDefaults.standard.set("opus; rm -rf ~", forKey: ClaudeSettings.reviewModelKey)
        UserDefaults.standard.set("claude-opus-5-5", forKey: ClaudeSettings.quickModelKey)
        UserDefaults.standard.set("ultra", forKey: ClaudeSettings.reviewEffortKey)
        XCTAssertEqual(ClaudeSettings.review.model, ClaudeSettings.reviewModelDefault)
        XCTAssertEqual(ClaudeSettings.review.effort, ClaudeSettings.reviewEffortDefault)
        XCTAssertEqual(ClaudeSettings.quick.model, ClaudeSettings.quickModelDefault)
    }

    func testLabels() {
        XCTAssertEqual(ClaudeSettings.label(("opus", "high")), "Opus · high")
        XCTAssertEqual(ClaudeSettings.label(("", "")), "default")
        XCTAssertEqual(ClaudeSettings.displayName("xhigh"), "Extra high")
        XCTAssertEqual(ClaudeSettings.displayName(ClaudeSettings.sameAsReview), "Same as reviews")
    }
}
