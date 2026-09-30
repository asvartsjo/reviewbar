# ReviewBar

A macOS menubar app that lists GitHub pull requests awaiting your review in selected repos, and hands them to Claude Code or OpenAI's Codex CLI for private review notes. Runs on your Claude or ChatGPT subscription login, not the API.

## What it does

- Lists open PRs where you are a requested reviewer, in the repos you choose (any mix of orgs and users).
- **Review with Claude** runs `claude -p` headlessly and shows a private summary, a lean (approve / comment / request changes), and findings with `file:line`, quoted code and a question to ask the author.
- **Review changes since…**: when a PR you reviewed gets new commits, review only those commits against your earlier notes (which concerns are resolved, still open, and what's new). If the branch was rebased or force-pushed the new commits can't be separated, so it falls back to the full diff with your notes, and says so. **Full review** is still there.
- **My PRs** also shows CI and merge state: merge conflicts and failing checks are listed even without new feedback, and so are approved PRs with green checks ("Ready to merge").
- **Terminal** (Settings): open Claude Code sessions in Terminal, iTerm2, Ghostty, WezTerm, kitty or Alacritty. Only installed ones are listed; **Automatic** (the default) picks the first installed of Ghostty, iTerm2, WezTerm, kitty, Alacritty, then Terminal. For anything else (Warp, …) choose **Copy command** and paste it into your terminal. When Claude exits you are left at a normal shell prompt.
- **Include draft PRs** (Settings, on by default) hides other people's drafts from Awaiting me and Replies when turned off; your own drafts always show in My PRs.
- **Awaiting me** lists the longest-open PRs first; ones open 3+ days are flagged.
- A running review can be cancelled. Hitting your Claude plan's usage limit shows a clear message (with the reset time when Claude Code gives one) instead of a failed review.
- If one watched repo can't be read by `gh` (typo, lost access, SSO), it is named and left out so the rest keep working; it is tried again when you change Settings.
- **Notifications** for new review requests, replies on your review threads and feedback on your PRs (each can be turned off in Settings). Clicking one opens the PR; several at once are grouped. The first refresh after launch only sets a baseline, so starting the app doesn't flood you.
- **Open at login** (Settings › Startup). Refreshes every 5 minutes and whenever you open the popover if the data is over a minute old.
- Reviews are saved locally and reload on launch, labelled with the model and effort that wrote them.
- **Settings › AI tool** switches between Claude Code and Codex. For Codex, type a model name (e.g. `gpt-5.5`) or leave it empty for your Codex config, and pick a reasoning effort; `OPENAI_API_KEY` is unset so it uses your ChatGPT login, and headless reviews run with `codex exec --sandbox read-only`.
- **Settings › Claude** picks a model and effort for anything that reads code (Review with Claude, every Terminal session), (default Opus), and a separate pair (default Sonnet, low effort) for **Summarise feedback**. Models are Claude Code aliases, so they follow the latest release in each family. That summary reads only comments, never the diff, so it reports what people said and what's waiting on you, not whether a fix is right. Terminal sessions get it as a starting point together with the full comments and diff. "Default" passes no model flag, so Claude Code's own settings apply.
- **Replies** lists open PRs you reviewed where someone answered in one of your unresolved review threads (the last comment isn't yours). Dismiss one to hide it until the next reply. The menu bar count includes them.
- **My PRs** lists your own open PRs with reviewer feedback you haven't answered: unresolved threads where a reviewer spoke last, and approvals, change requests, review summaries or comments newer than your last commit or comment. Bots are ignored. **Work through feedback in Terminal** opens Claude Code with all of it plus the diff, starting with a grouped list of what reviewers are asking for.
- **Follow up in Terminal** opens Claude Code seeded with the saved notes, the PR's reviews, review threads and conversation (your comments marked, unresolved threads first) and the current diff. It is offered for any PR with saved notes or replies.
- Nothing is ever posted to GitHub. Only read-only `gh` commands are used.

## Requirements

- macOS 13+ with Xcode 15+ or the Command Line Tools (Swift 5.9+); running the tests (`swift test`) needs Swift 6+ (Xcode 16+ or matching Command Line Tools)
- [`gh`](https://cli.github.com) logged in (`gh auth login`, authorise SSO if your org needs it)
- [Claude Code](https://claude.com/claude-code) logged in with your Max account (`claude`), or [Codex CLI](https://github.com/openai/codex) logged in with ChatGPT (`codex login`)

## Setup

```sh
git clone https://github.com/asvartsjo/reviewbar && cd reviewbar
scripts/make-app.sh              # builds build/ReviewBar.app
mv build/ReviewBar.app /Applications/
open /Applications/ReviewBar.app
```

Then click the eye in the menu bar, open the gear, and add repos as `owner/repo` (or paste GitHub URLs). Each is checked with `gh` when added, because one repo `gh` can't read makes GitHub reject the whole search.

The app is ad-hoc signed and not sandboxed (it runs `gh` and `claude`). No Xcode project is needed.

### Releases

Push a tag to build a drag-to-Applications `.dmg` (universal: Apple Silicon and Intel) and attach it to a GitHub Release:

```sh
git tag v0.1.0 && git push origin v0.1.0
```

Without a certificate the app is ad-hoc signed: fine for your own Mac (right-click › Open the first time), but macOS may ask again for notification and Terminal permissions after each update. Signing and notarization switch on by themselves once these repository secrets exist (Settings › Secrets and variables › Actions):

| Secret | What |
|---|---|
| `MACOS_CERT_P12` | `base64 -i cert.p12`, a **Developer ID Application** certificate exported from Keychain Access |
| `MACOS_CERT_PASSWORD` | the .p12 password |
| `APPLE_API_KEY_P8` | `base64 -i AuthKey_XXXX.p8`, an App Store Connect API key (for notarization) |
| `APPLE_API_KEY_ID` | that key's ID |
| `APPLE_API_ISSUER_ID` | the issuer ID from the App Store Connect keys page |

"Run workflow" on the Release workflow builds the `.dmg` as a run artifact without making a release. Locally: `scripts/make-app.sh && scripts/make-dmg.sh`.

### Developing

- `swift run` starts it straight from the source tree. Notifications and Open at login need the `.app` bundle, so they are disabled there. It uses a separate settings domain from the `.app`, so add your repos in each.
- `swift test` runs the unit tests (repo name parsing, model settings, feedback and reply counting from sample GitHub responses).
- `open Package.swift` opens it in Xcode.
- CI (GitHub Actions, macOS) builds, tests and bundles the app on every push; the zipped `.app` is attached to each run. A downloaded build is quarantined by macOS: right-click › Open the first time, or `xattr -dr com.apple.quarantine ReviewBar.app`.

## Notes

- Commands run through an interactive login zsh so `PATH` matches your Terminal.
- `ANTHROPIC_API_KEY` and `ANTHROPIC_AUTH_TOKEN` are unset for every `claude` call so the subscription is used, never API billing.
- Reviews are stored in `~/Library/Application Support/ReviewBar/` (`reviews.json` plus one `.md` per review).
- Diffs are capped at 250 KB. Terminal follow-ups refuse prompts over 800 KB (macOS argument limit).
- Headless reviews never get a shell or MCP servers (`--strict-mcp-config`). When the repo has a local clone (chosen in Settings, or found under `~/Projects`, `~/Developer`, …), the review runs in a worktree of the PR's head commit with read-only tools (`Read,Grep,Glob`; Codex: `--sandbox read-only --cd <worktree>`), so it can check callers and conventions instead of asking the author. Without a clone it gets no tools (`--tools ''`) and only sees the diff. This needs a recent Claude Code (`claude update`).
- A review is tied to the PR's head commit, so comments alone don't mark it stale; new commits do.
