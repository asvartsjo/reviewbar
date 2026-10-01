import Foundation
import Testing
@testable import ReviewBar

/// Serialized: every test here writes the same UserDefaults keys.
@Suite(.serialized)
final class ClaudeSettingsTests {
    private let keys = [ClaudeSettings.reviewModelKey, ClaudeSettings.reviewEffortKey,
                        ClaudeSettings.quickModelKey, ClaudeSettings.quickEffortKey]
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
}
