import XCTest
@testable import ReviewBar

final class MarkdownTests: XCTestCase {
    func testReviewShapedMarkdown() {
        let md = """
        ## Summary
        - Adds a cache
          - nested point
        1. First
        2) Second

        ## Things to check
        **should-fix** `src/a.ts:58`
        still the same paragraph
        ```ts
        await redis.del(key)
          indented()
        ```
        > quoted
        ---
        """
        XCTAssertEqual(MarkdownBlock.parse(md), [
            .heading(level: 2, text: "Summary"),
            .bullet(indent: 0, text: "Adds a cache"),
            .bullet(indent: 1, text: "nested point"),
            .numbered(indent: 0, number: "1", text: "First"),
            .numbered(indent: 0, number: "2", text: "Second"),
            .heading(level: 2, text: "Things to check"),
            .paragraph("**should-fix** `src/a.ts:58`\nstill the same paragraph"),
            .code(language: "ts", text: "await redis.del(key)\n  indented()"),
            .quote("quoted"),
            .rule,
        ])
    }

    func testNotHeadingsOrListsStayText() {
        XCTAssertEqual(MarkdownBlock.parse("#hashtag\n2026 was a year\n-dash"),
                       [.paragraph("#hashtag\n2026 was a year\n-dash")])
    }

    /// Claude sometimes forgets the closing fence; keep the code rather than dropping it.
    func testUnclosedFenceKeepsCode() {
        XCTAssertEqual(MarkdownBlock.parse("```\nlet x = 1"), [.code(language: "", text: "let x = 1")])
    }
}

final class ClaudeErrorsTests: XCTestCase {
    func testUsageLimitWithResetTime() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let m = ClaudeErrors.usageLimitMessage("Claude AI usage limit reached|1790003600", now: now)
        XCTAssertNotNil(m)
        XCTAssertTrue(m!.hasPrefix("Claude usage limit reached. It resets "))
        XCTAssertTrue(m!.hasSuffix("Try again then, or pick a lighter model in Settings."))
    }

    func testUsageLimitWithoutResetTime() {
        XCTAssertEqual(ClaudeErrors.usageLimitMessage("5-hour limit reached ∙ resets 3pm"),
                       "Claude usage limit reached. Try again then, or pick a lighter model in Settings.")
    }

    func testOrdinaryOutputIsNotALimit() {
        XCTAssertNil(ClaudeErrors.usageLimitMessage("## Summary\n- Adds rate limiting to the API"))
    }
}

final class TerminalAppTests: XCTestCase {
    func testLauncherScript() {
        let s = TerminalApp.launcherScript(claude: "env -u ANTHROPIC_API_KEY claude --model opus",
                                           promptFile: "/tmp/it's here/p.md", path: "/opt/homebrew/bin:/usr/bin")
        XCTAssertTrue(s.hasPrefix("#!/bin/zsh\n"))
        XCTAssertTrue(s.contains("export PATH='/opt/homebrew/bin:/usr/bin'"))
        // The prompt path is shell-quoted, including the apostrophe.
        XCTAssertTrue(s.contains(#"[[ -f '/tmp/it'\''s here/p.md' ]] || exit 0"#))
        XCTAssertTrue(s.contains(#"rm -f '/tmp/it'\''s here/p.md' "$0""#))
        XCTAssertTrue(s.contains(#"env -u ANTHROPIC_API_KEY claude --model opus "$prompt""#))
        XCTAssertTrue(s.contains(#"exec "${SHELL:-/bin/zsh}" -l"#))
    }

    func testLauncherWithoutPathSkipsExport() {
        XCTAssertFalse(TerminalApp.launcherScript(claude: "claude", promptFile: "/p", path: "").contains("export PATH"))
    }

    func testOpenCommands() {
        let (t, targs) = TerminalApp.terminal.openCommand(launcher: "/tmp/r.sh")
        XCTAssertEqual(t, "/usr/bin/osascript")
        XCTAssertTrue(targs[1].contains(#"tell application "Terminal""#))
        XCTAssertTrue(targs[1].contains(#"do script "'/tmp/r.sh'""#))

        let (i, iargs) = TerminalApp.iterm.openCommand(launcher: "/tmp/r.sh")
        XCTAssertEqual(i, "/usr/bin/osascript")
        XCTAssertTrue(iargs[1].contains(#"tell application "iTerm""#))
        XCTAssertTrue(iargs[1].contains(#"create window with default profile command "/tmp/r.sh""#))

        let (g, gargs) = TerminalApp.ghostty.openCommand(launcher: "/tmp/r.sh")
        XCTAssertEqual(g, "/usr/bin/open")
        XCTAssertEqual(gargs, ["-na", "Ghostty", "--args", "--window-save-state=never", "-e", "/tmp/r.sh"])
    }

    func testUnknownSavedValueFallsBackToTerminal() {
        let saved = UserDefaults.standard.object(forKey: TerminalApp.key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: TerminalApp.key) }
            else { UserDefaults.standard.removeObject(forKey: TerminalApp.key) }
        }
        UserDefaults.standard.set("warp", forKey: TerminalApp.key)
        XCTAssertEqual(TerminalApp.chosen, .terminal)
        UserDefaults.standard.set("ghostty", forKey: TerminalApp.key)
        XCTAssertEqual(TerminalApp.chosen, .ghostty)
    }
}
