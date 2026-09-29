# ReviewBar

A macOS menubar app that lists GitHub pull requests awaiting your review in selected repos, and hands them to Claude Code for private review notes. Runs on your Claude Max login, not the API.

## What it does

- Lists open PRs where you are a requested reviewer (org and repos configurable).
- **Review with Claude** runs `claude -p` headlessly and shows a private summary, a lean (approve / comment / request changes), and findings with `file:line`, quoted code and a question to ask the author.
- Reviews are saved locally and reload on launch.
- **Replies** lists open PRs you reviewed where someone answered in one of your unresolved review threads (the last comment isn't yours). Dismiss one to hide it until the next reply. The menu bar count includes them.
- **Follow up in Terminal** opens Claude Code seeded with the saved notes, the PR's review threads (your comments marked, unresolved first) and the current diff. It is offered for any PR with saved notes or replies.
- Nothing is ever posted to GitHub. Only read-only `gh` commands are used.

## Requirements

- macOS 13+, Xcode 15+
- [`gh`](https://cli.github.com) logged in (`gh auth login`, authorise SSO if your org needs it)
- [Claude Code](https://claude.com/claude-code) logged in with your Max account (`claude`)

## Setup

1. In Xcode create a new macOS App (SwiftUI), delete the template `ContentView.swift`, and add the files from `Sources/ReviewBar/`.
2. Signing & Capabilities: remove **App Sandbox** (needed to run `gh` and `claude`).
3. Target Info: add `Application is agent (UIElement)` = YES to hide the Dock icon.
4. Run, click the gear, and enter your org and repos.

## Notes

- Commands run through an interactive login zsh so `PATH` matches your Terminal.
- `ANTHROPIC_API_KEY` and `ANTHROPIC_AUTH_TOKEN` are unset for every `claude` call so the subscription is used, never API billing.
- Reviews are stored in `~/Library/Application Support/ReviewBar/` (`reviews.json` plus one `.md` per review).
- Diffs are capped at 250 KB. Terminal follow-ups refuse prompts over 800 KB (macOS argument limit).
- Headless reviews run with `--tools '' --strict-mcp-config`, so Claude cannot run commands or use MCP servers while reading an untrusted diff. This needs a recent Claude Code (`claude update`).
- A review is tied to the PR's head commit, so comments alone don't mark it stale; new commits do.
