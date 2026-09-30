import Testing
@testable import ReviewBar

struct DiffBudgetTests {
    private func file(_ p: String, _ lines: Int) -> String {
        "diff --git a/\(p) b/\(p)\n--- a/\(p)\n+++ b/\(p)\n@@ -1 +1 @@\n"
            + String(repeating: "+line of code here\n", count: lines)
    }

    @Test func smallDiffUnchanged() {
        let d = file("a.swift", 3)
        #expect(DiffBudget.fit(d, maxBytes: 10_000) == .init(diff: d, note: ""))
    }

    @Test func dropsNoiseAndShortensLargestFileOnly() {
        let d = [file("small.swift", 10), file("package-lock.json", 5000),
                 file("big.swift", 20000), file("mid.swift", 2000)].joined()
        let r = DiffBudget.fit(d, maxBytes: 100_000)
        #expect(r.diff.utf8.count <= 100_000)
        let parts = DiffBudget.files(r.diff)
        #expect(parts.map(\.path) == ["small.swift", "package-lock.json", "big.swift", "mid.swift"])
        #expect(parts[1].text.contains("omitted: generated or lockfile"))
        #expect(parts[2].text.contains("rest of this file's diff omitted"))
        #expect(!parts[3].text.contains("omitted"))
        #expect(r.note.contains("big.swift"))
    }

    @Test func rebuildsDiffFromFileEntries() {
        let e = [DiffBudget.FileEntry(filename: "b.swift", status: "renamed", additions: 1, deletions: 0,
                                      patch: "@@ -1 +1 @@\n+x", previous_filename: "a.swift"),
                 DiffBudget.FileEntry(filename: "img.png", status: "added", additions: 0, deletions: 0,
                                      patch: nil, previous_filename: nil)]
        let d = DiffBudget.diff(from: e)
        #expect(d.hasPrefix("diff --git a/a.swift b/b.swift"))
        #expect(DiffBudget.files(d).map(\.path) == ["b.swift", "img.png"])
    }
}
