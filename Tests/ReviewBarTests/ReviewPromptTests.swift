import Testing
@testable import ReviewBar

struct ReviewPromptTests {
    @Test func blankOrUnsetStyleIsTheBuiltInOne() {
        #expect(Backend.reviewStyle(saved: nil) == Backend.reviewStyleDefault)
        #expect(Backend.reviewStyle(saved: "  \n ") == Backend.reviewStyleDefault)
        #expect(Backend.reviewStyle(saved: "STYLE\n- Be terse.") == "STYLE\n- Be terse.")
    }

    @Test func editedStyleKeepsTheFixedParts() {
        let p = Backend.reviewPrompt(style: "STYLE\n- Be terse.", pr: "o/r#1 by a", url: "u",
                                     meta: "{}", note: "", diff: "DIFF-BODY")
        #expect(p.contains("- Be terse."))
        #expect(!p.contains("Sound like a colleague"))   // only in the built-in style
        #expect(p.contains(Backend.rules))
        #expect(p.contains(Backend.verdictLine))
        #expect(p.contains(Backend.findingFormat))
        #expect(p.hasSuffix("DIFF-BODY"))
    }

    @Test func previewShowsPlaceholdersAndFallsBackWhenBlank() {
        let p = Backend.reviewPromptPreview(style: "")
        #expect(p.contains(Backend.reviewStyleDefault))
        #expect(p.contains("owner/repo#123"))
    }
}
