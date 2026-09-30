import Foundation

/// Two model/effort pairs, stored in UserDefaults:
/// - review: "Review with Claude" and every Terminal session (anything that reads code)
/// - quick: "Summarise feedback", which reads only comments, never the diff
/// Models are Claude Code aliases, so each follows the latest model in its family.
/// An empty value passes no flag, so Claude Code's own configuration applies.
enum ClaudeSettings {
    static let models = ["opus", "sonnet", "haiku", "fable", ""]
    static let quickModels = [sameAsReview] + models
    static let efforts = ["", "low", "medium", "high", "xhigh", "max"]
    static let sameAsReview = "same"

    static let reviewModelKey = "reviewModel", reviewEffortKey = "reviewEffort"
    static let quickModelKey = "quickModel", quickEffortKey = "quickEffort"
    static let reviewModelDefault = "opus", reviewEffortDefault = ""
    static let quickModelDefault = "sonnet", quickEffortDefault = "low"
    static let reviewCommandKey = "reviewCommand", reviewCommandDefault = "/pr-review {url}"
    static let verifyCommandKey = "verifyCommand"
    static let verifyCommandDefault = "Verify fixes on {url}. My earlier review comments on GitHub are the baseline. "
        + "For each thread I started, check the commits since then and say: fixed / partly / not fixed / "
        + "author disagreed (with the reason). End with whether it's OK to approve, and ask me before "
        + "drafting any reply."

    private static func value(_ key: String, _ fallback: String, allowed: [String]) -> String {
        let v = UserDefaults.standard.string(forKey: key) ?? fallback
        return allowed.contains(v) ? v : fallback   // only whitelisted values reach the shell
    }

    static var review: (model: String, effort: String) {
        (value(reviewModelKey, reviewModelDefault, allowed: models),
         value(reviewEffortKey, reviewEffortDefault, allowed: efforts))
    }

    static var quick: (model: String, effort: String) {
        let m = value(quickModelKey, quickModelDefault, allowed: quickModels)
        let e = value(quickEffortKey, quickEffortDefault, allowed: efforts)
        return (m == sameAsReview ? review.model : m, e)
    }

    /// First message of a new terminal review, such as "/pr-review <url>" to run your own skill,
    /// or nil for the built-in review prompt.
    static func reviewCommand(for url: String) -> String? {
        command(UserDefaults.standard.string(forKey: reviewCommandKey) ?? reviewCommandDefault, url: url)
    }

    /// First message of a Verify fixes session, or nil when it's empty (no button).
    static func verifyCommand(for url: String) -> String? {
        command(UserDefaults.standard.string(forKey: verifyCommandKey) ?? verifyCommandDefault, url: url)
    }

    /// "{url}" replaced by `url`, or `url` appended when there is none. Blank means nil. Pure, for tests.
    static func command(_ template: String, url: String) -> String? {
        let t = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        return t.contains("{url}") ? t.replacingOccurrences(of: "{url}", with: url) : "\(t) \(url)"
    }

    /// Command-line flags for a pair, with a leading space, or "" for all defaults.
    static func flags(_ pair: (model: String, effort: String)) -> String {
        (pair.model.isEmpty ? "" : " --model \(pair.model)")
            + (pair.effort.isEmpty ? "" : " --effort \(pair.effort)")
    }

    /// Short label such as "Opus · high" or "default".
    static func label(_ pair: (model: String, effort: String)) -> String {
        let parts = [pair.model.isEmpty ? "" : displayName(pair.model), pair.effort].filter { !$0.isEmpty }
        return parts.isEmpty ? "default" : parts.joined(separator: " · ")
    }

    static func displayName(_ value: String) -> String {
        switch value {
        case "": return "Default"
        case sameAsReview: return "Same as reviews"
        case "xhigh": return "Extra high"
        default: return value.prefix(1).uppercased() + value.dropFirst()
        }
    }
}
