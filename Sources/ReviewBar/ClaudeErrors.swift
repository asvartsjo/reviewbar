import Foundation

enum ClaudeErrors {
    /// A readable message when Claude Code reports hitting the plan's usage limit, else nil.
    /// It prints e.g. "Claude AI usage limit reached|1759140000" (reset time, Unix seconds). Pure, for tests.
    static func usageLimitMessage(_ output: String, now: Date = Date()) -> String? {
        let lower = output.lowercased()
        guard lower.contains("usage limit") || lower.contains("limit reached") else { return nil }
        var message = "\(Agent.current.name) usage limit reached."
        if let r = output.range(of: #"\|(\d{9,11})"#, options: .regularExpression),
           let secs = TimeInterval(output[r].dropFirst()) {
            let reset = Date(timeIntervalSince1970: secs)
            if reset > now {
                message += " It resets \(reset.formatted(date: .omitted, time: .shortened))."
            }
        }
        return message + " Try again then, or pick a lighter model in Settings."
    }

    /// A readable message when an older Claude Code rejects a headless flag, else nil.
    /// It prints e.g. "error: unknown option '--setting-sources'". Pure, for tests.
    static func outdatedMessage(_ output: String) -> String? {
        guard output.lowercased().contains("error: unknown option") else { return nil }
        return "Claude Code is too old for ReviewBar's review flags. Run `claude update` and try again."
    }
}
