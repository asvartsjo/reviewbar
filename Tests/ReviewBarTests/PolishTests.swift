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

    func testLaunchCommands() {
        guard case .process(let t, let targs) = TerminalApp.terminal.launch(launcher: "/tmp/r.sh", app: "/System/Applications/Utilities/Terminal.app")
        else { return XCTFail() }
        XCTAssertEqual(t, "/usr/bin/osascript")
        XCTAssertTrue(targs[1].contains(#"tell application "Terminal""#))
        XCTAssertTrue(targs[1].contains(#"do script "'/tmp/r.sh'""#))

        guard case .process(let i, let iargs) = TerminalApp.iterm.launch(launcher: "/tmp/r.sh", app: "/Applications/iTerm.app")
        else { return XCTFail() }
        XCTAssertEqual(i, "/usr/bin/osascript")
        XCTAssertTrue(iargs[1].contains(#"create window with default profile command "/tmp/r.sh""#))

        XCTAssertEqual(TerminalApp.ghostty.launch(launcher: "/tmp/r.sh", app: "/Applications/Ghostty.app"),
                       .process("/usr/bin/open", ["-na", "/Applications/Ghostty.app", "--args",
                                                  "--window-save-state=never", "-e", "/tmp/r.sh"]))
        XCTAssertEqual(TerminalApp.wezterm.launch(launcher: "/tmp/r.sh", app: "/Applications/WezTerm.app"),
                       .process("/Applications/WezTerm.app/Contents/MacOS/wezterm", ["start", "--", "/tmp/r.sh"]))
        XCTAssertEqual(TerminalApp.kitty.launch(launcher: "/tmp/r.sh", app: "/Applications/kitty.app"),
                       .process("/usr/bin/open", ["-na", "/Applications/kitty.app", "--args", "/tmp/r.sh"]))
        XCTAssertEqual(TerminalApp.alacritty.launch(launcher: "/tmp/r.sh", app: "/Applications/Alacritty.app"),
                       .process("/usr/bin/open", ["-na", "/Applications/Alacritty.app", "--args", "-e", "/tmp/r.sh"]))
        XCTAssertEqual(TerminalApp.copy.launch(launcher: "/tmp/r.sh", app: ""), .copy("zsh '/tmp/r.sh'"))
    }

    func testAutomaticPrefersInstalledAlternativesOverTerminal() {
        XCTAssertEqual(TerminalApp.resolve(saved: "", installed: [.terminal, .iterm, .ghostty, .copy]), .ghostty)
        XCTAssertEqual(TerminalApp.resolve(saved: "", installed: [.terminal, .iterm, .copy]), .iterm)
        XCTAssertEqual(TerminalApp.resolve(saved: "", installed: [.terminal, .copy]), .terminal)
        XCTAssertEqual(TerminalApp.resolve(saved: "", installed: [.copy]), .copy)
    }

    func testSavedChoiceUsedOnlyWhileInstalled() {
        let here: [TerminalApp] = [.terminal, .iterm, .ghostty, .copy]
        XCTAssertEqual(TerminalApp.resolve(saved: "iterm", installed: here), .iterm)
        XCTAssertEqual(TerminalApp.resolve(saved: "copy", installed: here), .copy)
        // A colleague's Mac without Ghostty: fall back to automatic.
        XCTAssertEqual(TerminalApp.resolve(saved: "ghostty", installed: [.terminal, .copy]), .terminal)
        XCTAssertEqual(TerminalApp.resolve(saved: "warp", installed: here), .ghostty)
    }
}

final class NotificationPollTests: XCTestCase {
    func testChangedWithETagAndInterval() {
        let out = "HTTP/2.0 200 OK\r\nEtag: \"abc\"\r\nX-Poll-Interval: 60\r\n\r\n[]"
        XCTAssertEqual(Backend.parseNotificationPoll(out), .init(changed: true, etag: "\"abc\"", interval: 60))
    }

    func testNotModified() {
        XCTAssertEqual(Backend.parseNotificationPoll("HTTP/2.0 304 Not Modified\r\n\r\n")?.changed, false)
    }

    func testErrorsAreNil() {
        XCTAssertNil(Backend.parseNotificationPoll("HTTP/2.0 401 Unauthorized\r\n"))
        XCTAssertNil(Backend.parseNotificationPoll(""))
    }
}
