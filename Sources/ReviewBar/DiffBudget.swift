import Foundation

/// Fits a unified diff into a byte budget without losing whole files at the end: noise files
/// (lockfiles, minified, generated) are dropped first, then the largest files are shortened so
/// every changed file keeps at least its header and first hunks. Pure, for tests.
enum DiffBudget {
    struct Result: Equatable {
        let diff: String
        /// A line for the prompt when anything was left out, else "".
        let note: String
    }

    static let noiseSuffixes = [
        "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "Podfile.lock", "Package.resolved",
        "Cargo.lock", "Gemfile.lock", "composer.lock", "poetry.lock", "go.sum",
        ".min.js", ".min.css", ".map", ".snap", ".pb.go", ".g.dart", ".svg",
    ]
    static let noiseDirs = ["node_modules/", "vendor/", "dist/", "build/", "__generated__/", "generated/"]

    static func isNoise(_ path: String) -> Bool {
        noiseSuffixes.contains { path.hasSuffix($0) } || noiseDirs.contains { path.hasPrefix($0) || path.contains("/" + $0) }
    }

    /// Splits on `diff --git` headers into (path, text) pairs.
    static func files(_ diff: String) -> [(path: String, text: String)] {
        var out: [(String, String)] = []
        var current: [Substring] = []
        func flush() {
            guard let first = current.first else { return }
            let path = first.split(separator: " ").last.map { String($0.dropFirst(2)) } ?? "?"
            out.append((path, current.joined(separator: "\n")))
            current = []
        }
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") { flush() }
            current.append(line)
        }
        flush()
        return out.filter { !$0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    static func fit(_ diff: String, maxBytes: Int) -> Result {
        guard diff.utf8.count > maxBytes else { return Result(diff: diff, note: "") }
        var parts = files(diff)
        var skipped: [String] = []
        for i in parts.indices where isNoise(parts[i].path) {
            skipped.append(parts[i].path)
            parts[i].text = String(parts[i].text.split(separator: "\n").first ?? "") + "\n(omitted: generated or lockfile)"
        }

        var shortened: [String] = []
        // Water-filling: small files stay whole, large ones share what's left equally.
        let sizes = parts.map { $0.text.utf8.count + 1 }
        if sizes.reduce(0, +) > maxBytes {
            var remaining = maxBytes, left = parts.count
            var cap = Array(repeating: 0, count: parts.count)
            for i in sizes.indices.sorted(by: { sizes[$0] < sizes[$1] }) {
                let share = remaining / max(left, 1)
                cap[i] = min(sizes[i], share)
                remaining -= cap[i]; left -= 1
            }
            for i in parts.indices where cap[i] < sizes[i] {
                parts[i].text = cut(parts[i].text, to: max(cap[i] - 80, 200))
                    + "\n(… rest of this file's diff omitted to fit)"
                shortened.append(parts[i].path)
            }
        }

        var notes: [String] = []
        if !skipped.isEmpty { notes.append("skipped \(skipped.count) generated/lock file(s)") }
        if !shortened.isEmpty {
            notes.append("shortened \(shortened.count) large file(s): " + shortened.prefix(15).joined(separator: ", ")
                         + (shortened.count > 15 ? ", …" : ""))
        }
        let note = notes.isEmpty ? "" :
            "(NOTE: the diff was \(diff.utf8.count / 1000) KB, over the \(maxBytes / 1000) KB budget; "
            + notes.joined(separator: "; ") + ". Say so where it limits your answer.)\n"
        return Result(diff: parts.map(\.text).joined(separator: "\n"), note: note)
    }

    /// First `bytes` of `s`, ending at a line break.
    private static func cut(_ s: String, to bytes: Int) -> String {
        let head = String(decoding: Data(s.utf8.prefix(bytes)), as: UTF8.self)
        guard let nl = head.lastIndex(of: "\n") else { return head }
        return String(head[..<nl])
    }

    /// Rebuilds a unified diff from `GET /pulls/{n}/files` entries, for PRs too large for
    /// GitHub's diff endpoint. Files without a patch (binary, or huge) get a header only.
    struct FileEntry: Decodable {
        let filename: String
        let status: String
        let additions: Int
        let deletions: Int
        let patch: String?
        let previous_filename: String?
    }

    static func diff(from entries: [FileEntry]) -> String {
        entries.map { e in
            let old = e.previous_filename ?? e.filename
            var s = "diff --git a/\(old) b/\(e.filename)\n--- a/\(old)\n+++ b/\(e.filename)\n"
            s += e.patch ?? "(no patch from GitHub: \(e.status), +\(e.additions) −\(e.deletions))"
            return s
        }.joined(separator: "\n")
    }
}
