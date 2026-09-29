import Foundation

/// The coding agent that writes reviews and runs follow-ups: Claude Code or OpenAI's Codex CLI.
/// Both use the user's own subscription login; API keys are unset so neither bills an API account.
enum Agent: String, CaseIterable, Identifiable {
    case claude, codex

    static let key = "agent"
    static var current: Agent { Agent(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .claude }

    var id: String { rawValue }
    /// Short name for buttons: "Review with Codex".
    var name: String { self == .claude ? "Claude" : "Codex" }
    /// The CLI's product name: "Opens Codex in Ghostty".
    var appName: String { self == .claude ? "Claude Code" : "Codex" }
    var binary: String { self == .claude ? "claude" : "codex" }

    var review: (model: String, effort: String) { self == .claude ? ClaudeSettings.review : CodexSettings.review }
    var quick: (model: String, effort: String) { self == .claude ? ClaudeSettings.quick : CodexSettings.quick }

    /// "Codex · gpt-5.5 · high", or "Opus · high" for Claude (as saved before Codex existed).
    func label(_ pair: (model: String, effort: String)) -> String {
        switch self {
        case .claude: return ClaudeSettings.label(pair)
        case .codex:
            return (["Codex", pair.model, pair.effort].filter { !$0.isEmpty }).joined(separator: " · ")
        }
    }

    /// Shell command that reads the prompt on stdin and prints only the final answer. Pure, for tests.
    func headlessCommand(_ pair: (model: String, effort: String)) -> String {
        switch self {
        case .claude:
            return "\(Backend.claudeBin) \(Backend.headlessFlags)\(ClaudeSettings.flags(pair))"
        case .codex:
            // Read-only sandbox: the diff is untrusted input. The answer goes to a file so
            // progress output on stdout never ends up in the saved review.
            return "f=$(mktemp -t reviewbar) || exit 1; "
                + "\(CodexSettings.bin) exec --skip-git-repo-check --sandbox read-only --color never "
                + "--output-last-message \"$f\"\(CodexSettings.flags(pair)) - >/dev/null "
                + "|| { s=$?; rm -f \"$f\"; exit $s; }; cat \"$f\"; rm -f \"$f\""
        }
    }

    /// Interactive command; the launcher appends the prompt as one argument.
    func interactiveCommand(_ pair: (model: String, effort: String)) -> String {
        switch self {
        case .claude: return "\(Backend.claudeBin)\(ClaudeSettings.flags(pair))"
        case .codex: return "\(CodexSettings.bin)\(CodexSettings.flags(pair))"
        }
    }
}

enum CodexSettings {
    static let bin = "env -u OPENAI_API_KEY codex"
    static let efforts = ["", "minimal", "low", "medium", "high", "xhigh"]
    static let sameAsReview = ClaudeSettings.sameAsReview

    static let reviewModelKey = "codexReviewModel", reviewEffortKey = "codexReviewEffort"
    static let quickModelKey = "codexQuickModel", quickEffortKey = "codexQuickEffort"
    static let quickEffortDefault = "low"

    /// Model names are free text (OpenAI renames often), so only safe characters reach the shell.
    static func isValidModel(_ s: String) -> Bool {
        s.count <= 60 && s.allSatisfy { $0.isLetter || $0.isNumber || "._-".contains($0) }
    }

    private static func model(_ key: String) -> String {
        let v = (UserDefaults.standard.string(forKey: key) ?? "").trimmingCharacters(in: .whitespaces)
        return isValidModel(v) ? v : ""
    }

    private static func effort(_ key: String, _ fallback: String = "") -> String {
        let v = UserDefaults.standard.string(forKey: key) ?? fallback
        return efforts.contains(v) ? v : fallback
    }

    static var review: (model: String, effort: String) { (model(reviewModelKey), effort(reviewEffortKey)) }

    /// An empty summary model means "same as reviews".
    static var quick: (model: String, effort: String) {
        let m = model(quickModelKey)
        return (m.isEmpty ? review.model : m, effort(quickEffortKey, quickEffortDefault))
    }

    static func flags(_ pair: (model: String, effort: String)) -> String {
        (pair.model.isEmpty ? "" : " --model \(pair.model)")
            + (pair.effort.isEmpty ? "" : " -c model_reasoning_effort=\(pair.effort)")
    }
}
