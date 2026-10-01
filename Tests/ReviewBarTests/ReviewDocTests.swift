import Testing
@testable import ReviewBar

struct ReviewDocTests {
    @Test func verdictAndFindingBoxes() {
        let doc = ReviewDoc.parse("""
        VERDICT: Request changes — refresh can race.

        ## Findings
        ### [blocker] `a.swift:4` Race
        Why: two refreshes.
        > Could two requests hit this at once?

        ### [nit] `a.swift:9` Stray print

        ## Good
        - Tests.
        """)
        #expect(doc.first == .verdict(.requestChanges, reason: "refresh can race."))
        let findings = doc.compactMap { s -> ReviewDoc.Severity?? in
            if case .finding(let sev, _, _) = s { return sev } else { return nil }
        }
        #expect(findings == [.blocker, .nit])
        #expect(doc.contains(.block(.heading(level: 2, text: "Good"))))
    }

    @Test func legacyLeanBecomesVerdict() {
        #expect(ReviewDoc.parse("## Lean\nApprove, small and safe.").first
                == .verdict(.approve, reason: "small and safe."))
    }

    @Test func noVerdictIsFine() {
        #expect(ReviewDoc.parse("Just notes.") == [.block(.paragraph("Just notes."))])
    }
}

struct PostableCommentTests {
    @Test func questionSeverityAndPostableComment() {
        let doc = ReviewDoc.parse("""
        ### [question] `a.swift:3` Archived projects?
        Why: old query excluded them.
        > question: Is this meant to include archived projects? The old query excluded them.
        ```suggestion
        .filter { !$0.archived }
        ```
        """)
        guard case .finding(let sev, _, let blocks) = doc.first else { Issue.record("no finding"); return }
        #expect(sev == .question)
        #expect(ReviewDoc.postable(blocks)
                == "question: Is this meant to include archived projects? The old query excluded them.\n\n"
                + "```suggestion\n.filter { !$0.archived }\n```")
    }

    @Test func noCommentNoButton() {
        #expect(ReviewDoc.postable([.paragraph("Why: x")]) == nil)
    }
}
