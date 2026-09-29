import XCTest
@testable import ReviewBar

final class AgentTests: XCTestCase {
    func testCodexHeadlessIsReadOnlyAndKeepsOnlyTheAnswer() {
        let cmd = Agent.codex.headlessCommand((model: "gpt-5.5", effort: "high"))
        XCTAssertTrue(cmd.contains("env -u OPENAI_API_KEY codex exec"))
        XCTAssertTrue(cmd.contains("--sandbox read-only"))
        XCTAssertTrue(cmd.contains("--output-last-message"))
        XCTAssertTrue(cmd.contains("--model gpt-5.5 -c model_reasoning_effort=high -"))
    }

    func testClaudeCommandsUnchanged() {
        XCTAssertEqual(Agent.claude.headlessCommand((model: "opus", effort: "")),
                       "\(Backend.claudeBin) \(Backend.headlessFlags) --tools '' --model opus")
        XCTAssertEqual(Agent.claude.interactiveCommand((model: "", effort: "")), Backend.claudeBin)
    }

    func testCodebaseGivesReadOnlyToolsInTheWorktree() {
        let c = Agent.claude.headlessCommand((model: "", effort: ""), codebase: "/wt/it's")
        XCTAssertTrue(c.hasPrefix(#"cd '/wt/it'\''s' && "#))
        XCTAssertTrue(c.contains("--tools 'Read,Grep,Glob'"))
        XCTAssertFalse(c.contains("Bash"))
        let x = Agent.codex.headlessCommand((model: "", effort: ""), codebase: "/wt")
        XCTAssertTrue(x.contains("--sandbox read-only --color never --cd '/wt' "))
    }

    func testCodexModelNamesAreShellSafe() {
        XCTAssertTrue(CodexSettings.isValidModel("gpt-5.5-codex"))
        XCTAssertTrue(CodexSettings.isValidModel(""))
        XCTAssertFalse(CodexSettings.isValidModel("gpt; rm -rf ~"))
        XCTAssertFalse(CodexSettings.isValidModel("$(x)"))
    }

    func testLabels() {
        XCTAssertEqual(Agent.codex.label((model: "gpt-5.5", effort: "high")), "Codex · gpt-5.5 · high")
        XCTAssertEqual(Agent.codex.label((model: "", effort: "")), "Codex")
    }
}
