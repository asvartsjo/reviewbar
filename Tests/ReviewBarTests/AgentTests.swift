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
        let x = Agent.codex.headlessCommand((model: "", effort: ""), codebase: "/wt")
        #expect(x.contains("--sandbox read-only --color never --cd '/wt' "))
    }

    @Test func codexHeadlessIgnoresThePRsAgentsMd() {
        let x = Agent.codex.headlessCommand((model: "", effort: ""), codebase: "/wt")
        #expect(x.contains("--cd '/wt' -c project_doc_max_bytes=0 "))
        #expect(!Agent.codex.interactiveCommand((model: "", effort: "")).contains("project_doc_max_bytes"))
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
