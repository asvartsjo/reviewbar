import Foundation
import Testing
@testable import ReviewBar

/// Serialized: every test here writes the same UserDefaults keys.
@Suite(.serialized)
final class ClaudeSettingsTests {
    private let keys = [ClaudeSettings.reviewModelKey, ClaudeSettings.reviewEffortKey,
                        ClaudeSettings.quickModelKey, ClaudeSettings.quickEffortKey,
                        ClaudeSettings.reviewCommandKey, ClaudeSettings.verifyCommandKey]
    private var saved: [String: Any] = [:]

    init() {
        for k in keys { saved[k] = UserDefaults.standard.object(forKey: k) }
        for k in keys { UserDefaults.standard.removeObject(forKey: k) }
    }

    deinit {
        for k in keys {
            if let v = saved[k] { UserDefaults.standard.set(v, forKey: k) }
            else { UserDefaults.standard.removeObject(forKey: k) }
        }
    }

    @Test func defaults() {
        #expect(ClaudeSettings.review.model == "opus")
        #expect(ClaudeSettings.review.effort == "")
        #expect(ClaudeSettings.quick.model == "sonnet")
        #expect(ClaudeSettings.quick.effort == "low")
    }

    @Test func flags() {
        #expect(ClaudeSettings.flags(("opus", "high")) == " --model opus --effort high")
        #expect(ClaudeSettings.flags(("sonnet", "")) == " --model sonnet")
        #expect(ClaudeSettings.flags(("", "")) == "")
    }

    @Test func sameAsReviewUsesReviewModel() {
        UserDefaults.standard.set("haiku", forKey: ClaudeSettings.reviewModelKey)
        UserDefaults.standard.set(ClaudeSettings.sameAsReview, forKey: ClaudeSettings.quickModelKey)
        #expect(ClaudeSettings.quick.model == "haiku")
    }

    /// Only whitelisted values may reach the shell command line.
    @Test func unknownValuesFallBackToDefaults() {
        UserDefaults.standard.set("opus; rm -rf ~", forKey: ClaudeSettings.reviewModelKey)
        UserDefaults.standard.set("claude-opus-5-5", forKey: ClaudeSettings.quickModelKey)
        UserDefaults.standard.set("ultra", forKey: ClaudeSettings.reviewEffortKey)
        #expect(ClaudeSettings.review.model == ClaudeSettings.reviewModelDefault)
        #expect(ClaudeSettings.review.effort == ClaudeSettings.reviewEffortDefault)
        #expect(ClaudeSettings.quick.model == ClaudeSettings.quickModelDefault)
    }

    @Test func labels() {
        #expect(ClaudeSettings.label(("opus", "high")) == "Opus · high")
        #expect(ClaudeSettings.label(("", "")) == "default")
        #expect(ClaudeSettings.displayName("xhigh") == "Extra high")
        #expect(ClaudeSettings.displayName(ClaudeSettings.sameAsReview) == "Same as reviews")
    }

    @Test func reviewCommand() {
        let url = "https://github.com/o/r/pull/7"
        #expect(ClaudeSettings.reviewCommand(for: url) == nil)
        UserDefaults.standard.set("/pr-review {url}", forKey: ClaudeSettings.reviewCommandKey)
        #expect(ClaudeSettings.reviewCommand(for: url) == "/pr-review \(url)")
        #expect(ClaudeSettings.command("/pr-review {url} --deep", url: url) == "/pr-review \(url) --deep")
        #expect(ClaudeSettings.command("  /pr-review  ", url: url) == "/pr-review \(url)")
        #expect(ClaudeSettings.command(" \n ", url: url) == nil)
        UserDefaults.standard.set("", forKey: ClaudeSettings.reviewCommandKey)
        #expect(ClaudeSettings.reviewCommand(for: url) == nil)
    }

    @Test func verifyCommand() throws {
        let url = "https://github.com/o/r/pull/7"
        let command = try #require(ClaudeSettings.verifyCommand(for: url))
        #expect(command.hasPrefix("Verify fixes on \(url). My earlier review comments on GitHub are the baseline."))
        #expect(!command.contains("{url}"))
        UserDefaults.standard.set("  ", forKey: ClaudeSettings.verifyCommandKey)
        #expect(ClaudeSettings.verifyCommand(for: url) == nil)
    }
}
