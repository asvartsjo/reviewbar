import Foundation
import Testing
@testable import ReviewBar

struct AgentTests {
    @Test func codexHeadlessIsReadOnlyAndKeepsOnlyTheAnswer() {
        let cmd = Agent.codex.headlessCommand((model: "gpt-5.5", effort: "high"))
        #expect(cmd.contains("env -u OPENAI_API_KEY codex exec"))
        #expect(cmd.contains("--sandbox read-only"))
        #expect(cmd.contains("--output-last-message"))
        #expect(cmd.contains("--model gpt-5.5 -c model_reasoning_effort=high -"))
    }

    @Test func claudeCommandsUnchanged() {
        #expect(Agent.claude.headlessCommand((model: "opus", effort: ""))
                == "\(Backend.claudeBin) \(Backend.headlessFlags) --tools '' --model opus")
        #expect(Agent.claude.interactiveCommand((model: "", effort: "")) == Backend.claudeBin)
    }

    @Test func codebaseGivesReadOnlyToolsInTheWorktree() {
        let c = Agent.claude.headlessCommand((model: "", effort: ""), codebase: "/wt/it's")
        #expect(c.hasPrefix(#"cd '/wt/it'\''s' && "#))
        #expect(c.contains("--tools 'Read,Grep,Glob'"))
        #expect(!c.contains("Bash"))
        #expect(c.contains(#"--settings '{"disableAllHooks":true}'"#))
        #expect(c.contains("--strict-mcp-config"))
        #expect(!c.contains("--setting-sources"))
        let x = Agent.codex.headlessCommand((model: "", effort: ""), codebase: "/wt")
        #expect(x.contains("--sandbox read-only --color never --cd '/wt' "))
    }

    @Test func projectSettingsInTheWorktreeAreSkipped() throws {
        let c = Agent.claude.headlessCommand((model: "", effort: ""), codebase: "/wt", userSettingsOnly: true)
        #expect(c.contains("--setting-sources user"))
        #expect(c.contains(#"--settings '{"disableAllHooks":true}'"#))

        let wt = FileManager.default.temporaryDirectory.appendingPathComponent("reviewbar-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: wt) }
        try FileManager.default.createDirectory(at: wt.appendingPathComponent(".claude/rules"),
                                                withIntermediateDirectories: true)
        try "# rules".write(to: wt.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        #expect(!Backend.hasProjectSettings(wt.path))
        try "{}".write(to: wt.appendingPathComponent(".claude/settings.local.json"), atomically: true, encoding: .utf8)
        #expect(Backend.hasProjectSettings(wt.path))
    }

    @Test func noteGoesUnderTheVerdict() {
        let review = "VERDICT: Comment — one question\n\n## Summary\n- Adds a cart"
        let noted = Backend.withNote(review, "_note_")
        #expect(noted == "VERDICT: Comment — one question\n\n_note_\n\n## Summary\n- Adds a cart")
        guard case .verdict(.comment, let reason) = ReviewDoc.parse(noted).first else {
            Issue.record("verdict not parsed first"); return
        }
        #expect(reason == "one question")
        #expect(Backend.withNote("## Summary", "_note_") == "_note_\n\n## Summary")
    }

    @Test func codexModelNamesAreShellSafe() {
        #expect(CodexSettings.isValidModel("gpt-5.5-codex"))
        #expect(CodexSettings.isValidModel(""))
        #expect(!CodexSettings.isValidModel("gpt; rm -rf ~"))
        #expect(!CodexSettings.isValidModel("$(x)"))
    }

    @Test func labels() {
        #expect(Agent.codex.label((model: "gpt-5.5", effort: "high")) == "Codex · gpt-5.5 · high")
        #expect(Agent.codex.label((model: "", effort: "")) == "Codex")
    }
}
