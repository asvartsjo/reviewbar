import Foundation
import Testing
@testable import ReviewBar

struct MarkdownTests {
    @Test func reviewShapedMarkdown() {
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
        #expect(MarkdownBlock.parse(md) == [
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

    @Test func notHeadingsOrListsStayText() {
        #expect(MarkdownBlock.parse("#hashtag\n2026 was a year\n-dash")
                == [.paragraph("#hashtag\n2026 was a year\n-dash")])
    }

    /// Claude sometimes forgets the closing fence; keep the code rather than dropping it.
    @Test func unclosedFenceKeepsCode() {
        #expect(MarkdownBlock.parse("```\nlet x = 1") == [.code(language: "", text: "let x = 1")])
    }
}

struct ClaudeErrorsTests {
    @Test func usageLimitWithResetTime() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let m = try #require(ClaudeErrors.usageLimitMessage("Claude AI usage limit reached|1790003600", now: now))
        #expect(m.hasPrefix("Claude usage limit reached. It resets "))
        #expect(m.hasSuffix("Try again then, or pick a lighter model in Settings."))
    }

    @Test func usageLimitWithoutResetTime() {
        #expect(ClaudeErrors.usageLimitMessage("5-hour limit reached ∙ resets 3pm")
                == "Claude usage limit reached. Try again then, or pick a lighter model in Settings.")
    }

    @Test func ordinaryOutputIsNotALimit() {
        #expect(ClaudeErrors.usageLimitMessage("## Summary\n- Adds rate limiting to the API") == nil)
    }
}

struct TerminalAppTests {
    @Test func launcherScript() {
        let s = TerminalApp.launcherScript(claude: "env -u ANTHROPIC_API_KEY claude --model opus",
                                           promptFile: "/tmp/it's here/p.md", path: "/opt/homebrew/bin:/usr/bin")
        #expect(s.hasPrefix("#!/bin/zsh\n"))
        #expect(s.contains("export PATH='/opt/homebrew/bin:/usr/bin'"))
        // The prompt path is shell-quoted, including the apostrophe.
        #expect(s.contains(#"[[ -f '/tmp/it'\''s here/p.md' ]] || exit 0"#))
        #expect(s.contains(#"rm -f '/tmp/it'\''s here/p.md' "$0""#))
        #expect(s.contains(#"env -u ANTHROPIC_API_KEY claude --model opus "$prompt""#))
        #expect(s.contains(#"exec "${SHELL:-/bin/zsh}" -l"#))
    }

    /// My PR commands start in the checkout of the PR's branch, quoted, and stop if it's gone.
    @Test func launcherStartsInADirectory() {
        let s = TerminalApp.launcherScript(claude: "claude", promptFile: "/p", path: "", directory: "/Users/me/it's/gauss-x")
        #expect(s.contains(#"cd '/Users/me/it'\''s/gauss-x' || exit 1"#))
        #expect(!TerminalApp.launcherScript(claude: "claude", promptFile: "/p", path: "").contains("cd "))
    }

    @Test func launcherWithoutPathSkipsExport() {
        #expect(!TerminalApp.launcherScript(claude: "claude", promptFile: "/p", path: "").contains("export PATH"))
    }

    @Test func launchCommands() {
        guard case .process(let t, let targs) = TerminalApp.terminal.launch(launcher: "/tmp/r.sh", app: "/System/Applications/Utilities/Terminal.app")
        else { Issue.record(); return }
        #expect(t == "/usr/bin/osascript")
        #expect(targs[1].contains(#"tell application "Terminal""#))
        #expect(targs[1].contains(#"do script "'/tmp/r.sh'""#))

        guard case .process(let i, let iargs) = TerminalApp.iterm.launch(launcher: "/tmp/r.sh", app: "/Applications/iTerm.app")
        else { Issue.record(); return }
        #expect(i == "/usr/bin/osascript")
        #expect(iargs[1].contains(#"create window with default profile command "/tmp/r.sh""#))

        #expect(TerminalApp.ghostty.launch(launcher: "/tmp/r.sh", app: "/Applications/Ghostty.app")
                == .process("/usr/bin/open", ["-na", "/Applications/Ghostty.app", "--args",
                                              "--window-save-state=never", "-e", "/tmp/r.sh"]))
        #expect(TerminalApp.wezterm.launch(launcher: "/tmp/r.sh", app: "/Applications/WezTerm.app")
                == .process("/Applications/WezTerm.app/Contents/MacOS/wezterm", ["start", "--", "/tmp/r.sh"]))
        #expect(TerminalApp.kitty.launch(launcher: "/tmp/r.sh", app: "/Applications/kitty.app")
                == .process("/usr/bin/open", ["-na", "/Applications/kitty.app", "--args", "/tmp/r.sh"]))
        #expect(TerminalApp.alacritty.launch(launcher: "/tmp/r.sh", app: "/Applications/Alacritty.app")
                == .process("/usr/bin/open", ["-na", "/Applications/Alacritty.app", "--args", "-e", "/tmp/r.sh"]))
        #expect(TerminalApp.copy.launch(launcher: "/tmp/r.sh", app: "") == .copy("zsh '/tmp/r.sh'"))
    }

    @Test func automaticPrefersInstalledAlternativesOverTerminal() {
        #expect(TerminalApp.resolve(saved: "", installed: [.terminal, .iterm, .ghostty, .copy]) == .ghostty)
        #expect(TerminalApp.resolve(saved: "", installed: [.terminal, .iterm, .copy]) == .iterm)
        #expect(TerminalApp.resolve(saved: "", installed: [.terminal, .copy]) == .terminal)
        #expect(TerminalApp.resolve(saved: "", installed: [.copy]) == .copy)
    }

    @Test func savedChoiceUsedOnlyWhileInstalled() {
        let here: [TerminalApp] = [.terminal, .iterm, .ghostty, .copy]
        #expect(TerminalApp.resolve(saved: "iterm", installed: here) == .iterm)
        #expect(TerminalApp.resolve(saved: "copy", installed: here) == .copy)
        // A colleague's Mac without Ghostty: fall back to automatic.
        #expect(TerminalApp.resolve(saved: "ghostty", installed: [.terminal, .copy]) == .terminal)
        #expect(TerminalApp.resolve(saved: "warp", installed: here) == .ghostty)
    }
}

struct NotificationPollTests {
    @Test func changedWithETagAndInterval() {
        let out = "HTTP/2.0 200 OK\r\nEtag: \"abc\"\r\nX-Poll-Interval: 60\r\n\r\n[]"
        #expect(Backend.parseNotificationPoll(out) == .init(changed: true, etag: "\"abc\"", interval: 60))
    }

    @Test func notModified() {
        #expect(Backend.parseNotificationPoll("HTTP/2.0 304 Not Modified\r\n\r\n")?.changed == false)
    }

    @Test func errorsAreNil() {
        #expect(Backend.parseNotificationPoll("HTTP/2.0 401 Unauthorized\r\n") == nil)
        #expect(Backend.parseNotificationPoll("") == nil)
    }
}

struct RevealScriptTests {
    @Test func iTermAndTerminalLookUpTheTabByTTY() throws {
        let iterm = try #require(TerminalApp.iterm.revealScript(tty: "ttys005"))
        #expect(iterm.contains(#"tell application "iTerm""#))
        #expect(iterm.contains(#"if tty of s is "/dev/ttys005" then"#))
        let terminal = try #require(TerminalApp.terminal.revealScript(tty: "ttys012"))
        #expect(terminal.contains(#"if tty of t is "/dev/ttys012" then"#))
    }

    /// The tty goes into AppleScript, so only a plain ttysNNN gets through.
    @Test func onlyAPlainTTYIsAccepted() {
        for bad in ["", "??", "ttys", "ttys5\"; do shell script \"x", "/dev/ttys005", "pts/1"] {
            #expect(TerminalApp.iterm.revealScript(tty: bad) == nil, "\(bad)")
        }
    }

    @Test func otherTerminalsCantBeSearched() {
        #expect(TerminalApp.ghostty.revealScript(tty: "ttys005") == nil)
        #expect(TerminalApp.copy.revealScript(tty: "ttys005") == nil)
    }
}
