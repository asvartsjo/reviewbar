import Foundation

/// Turns a saved review into a pending (draft) GitHub review: one line comment per finding,
/// nits left out. GitHub keeps a review without an `event` pending, visible only to you,
/// until you submit it on the PR page.
enum DraftReview {
    struct Comment: Equatable {
        let path: String
        let line: Int
        let startLine: Int?
        let body: String
    }

    /// Non-nit findings that have a postable comment and a `path:line` in their title. Pure, for tests.
    static func comments(from review: String) -> [Comment] {
        ReviewDoc.parse(review).compactMap { segment -> Comment? in
            guard case .finding(let sev, let title, let blocks) = segment, sev != .nit,
                  var body = ReviewDoc.postable(blocks), let loc = location(in: title) else { return nil }
            // A suggestion replaces exactly the commented lines: without a range, a multi-line
            // one would overwrite the wrong code when applied, so it becomes a plain code block.
            if loc.start == nil, let r = body.range(of: "```suggestion\n"),
               let end = body.range(of: "\n```", range: r.upperBound..<body.endIndex),
               body[r.upperBound..<end.lowerBound].contains("\n") {
                body.replaceSubrange(r, with: "```\n")
            }
            return Comment(path: loc.path, line: loc.line, startLine: loc.start, body: body)
        }
    }

    /// `path/to/file.ext:42` or `path:40-44` inside backticks in a finding's title.
    static func location(in title: String) -> (path: String, line: Int, start: Int?)? {
        guard let m = title.range(of: #"`[^`\s]+:\d+(-\d+)?`"#, options: .regularExpression) else { return nil }
        let token = title[m].dropFirst().dropLast()
        guard let colon = token.lastIndex(of: ":") else { return nil }
        let path = String(token[..<colon])
        let nums = token[token.index(after: colon)...].split(separator: "-").compactMap { Int($0) }
        guard let first = nums.first else { return nil }
        return nums.count == 2 && nums[1] > first ? (path, nums[1], first) : (path, first, nil)
    }

    /// New-file line numbers GitHub accepts comments on (added and context lines in the hunks),
    /// per path. Pure, for tests.
    static func commentableLines(_ diff: String) -> [String: Set<Int>] {
        var out: [String: Set<Int>] = [:]
        var path: String?, line = 0
        for raw in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if raw.hasPrefix("+++ ") {
                let p = raw.dropFirst(4)
                path = p.hasPrefix("b/") ? String(p.dropFirst(2)) : (p == "/dev/null" ? nil : String(p))
            } else if raw.hasPrefix("@@"), let r = raw.range(of: #"\+(\d+)"#, options: .regularExpression) {
                line = Int(raw[r].dropFirst()) ?? 0
            } else if let p = path, line > 0 {
                if raw.hasPrefix("+") || raw.hasPrefix(" ") { out[p, default: []].insert(line); line += 1 }
                else if raw.hasPrefix("\\") || raw.hasPrefix("-") { continue }
                else if raw.hasPrefix("diff --git") { path = nil; line = 0 }
            }
        }
        return out
    }

    /// The API request body. Comments GitHub would reject (outside the diff) go in the review
    /// body instead, so nothing is lost. Pure, for tests.
    static func requestBody(comments: [Comment], commentable: [String: Set<Int>], commit: String?) -> [String: Any] {
        var inline: [[String: Any]] = [], loose: [String] = []
        for c in comments {
            let lines = commentable[c.path] ?? []
            if lines.contains(c.line), c.startLine.map({ lines.contains($0) }) ?? true {
                var entry: [String: Any] = ["path": c.path, "line": c.line, "side": "RIGHT", "body": c.body]
                if let s = c.startLine { entry["start_line"] = s; entry["start_side"] = "RIGHT" }
                inline.append(entry)
            } else {
                loose.append("**`\(c.path):\(c.line)`**\n\n\(c.body)")
            }
        }
        var body: [String: Any] = ["comments": inline]
        if !loose.isEmpty { body["body"] = loose.joined(separator: "\n\n---\n\n") }
        if let commit { body["commit_id"] = commit }
        return body
    }
}
