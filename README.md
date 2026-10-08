# ReviewBar

A macOS menubar app that lists GitHub pull requests awaiting your review in selected repos, and hands them to Claude Code or OpenAI's Codex CLI for private review notes. Runs on your Claude or ChatGPT subscription login, not the API.

Nothing is ever posted to GitHub. Only read-only `gh` commands are used.

## At a glance

- **Reviewing**: every open PR you review, grouped by whose turn it is, with thread, approval and CI status.
- **My PRs**: your own open PRs, grouped by whose move it is: conflicts, failing checks, unanswered feedback, ready to merge.
- **Crew** (Claude Code): the Claude sessions working in your watched repos, those waiting on you first.
- **Review with Claude** (or Codex): a private summary, a lean (approve / comment / request changes) and findings with `file:line`, quoted code and a question to ask the author.
- **Review changes since…**: re-review only the commits since your last review, against your earlier notes.
- **Terminal hand-offs**: open Claude Code in your terminal for a review, a follow-up, verifying fixes or working through feedback on your own PR.
- **Notifications** and a **menu bar number** for what needs you.

How each of these works, every setting, and what keeps headless reviews safe: **[docs/features.md](docs/features.md)**.

## Requirements

- macOS 14+ to run it; Xcode 16+ or the Command Line Tools with Swift 6+ to build it
- [`gh`](https://cli.github.com) logged in (`gh auth login`, authorise SSO if your org needs it)
- [Claude Code](https://claude.com/claude-code) logged in with your Max account (`claude`), or [Codex CLI](https://github.com/openai/codex) logged in with ChatGPT (`codex login`)

## Install

Build it from source. You don't need an Apple developer account or Xcode, only the Command Line Tools (`xcode-select --install`).

1. Install and log in to the tools ReviewBar shells out to:

   ```sh
   brew install gh && gh auth login        # authorise SSO if your org needs it
   claude                                  # Claude Code: log in once, then exit
   # or: codex login                       # Codex CLI instead of Claude
   ```

2. Build and install the app:

   ```sh
   git clone https://github.com/asvartsjo/reviewbar && cd reviewbar
   scripts/make-app.sh              # builds build/ReviewBar.app
   mv build/ReviewBar.app /Applications/
   open /Applications/ReviewBar.app
   ```

3. Click the eye in the menu bar, open the gear, and add repos as `owner/repo` (or paste GitHub URLs). Each is checked with `gh` when added, because one repo `gh` can't read makes GitHub reject the whole search.

The app is ad-hoc signed and not sandboxed (it runs `gh` and `claude`). Because you build it yourself it isn't quarantined, so Gatekeeper doesn't complain. macOS asks for notification and Automation (Terminal) permission the first time they're needed.

**Update:** quit the app, `git pull`, then run the same build and `mv` again.

**Uninstall:** delete `/Applications/ReviewBar.app` and, to drop saved reviews, `~/Library/Application Support/ReviewBar/`.

**Troubleshooting**

- `plugin for module 'TestingMacros' not found` only affects `swift test`; see [Developing](#developing).
- If the app can't find `gh`, `claude` or `codex`, check that `which gh claude` works in a new Terminal window: the app uses your login shell's `PATH`.

## Settings

Open the gear in the panel. Details for each: [docs/features.md › Settings](docs/features.md#settings).

| Section | What you set |
|---|---|
| Repositories | The repos to watch, as `owner/repo` |
| AI tool | Claude Code or Codex, and the model and effort for reviews and for Summarise feedback |
| Terminal | Which terminal opens Claude Code sessions, the Review, Verify and Triage feedback commands, and where PR worktrees go |
| Review prompt | How reviews are written and how suggested comments are worded |
| Pull requests | Whether other people's drafts show in Reviewing |
| Notifications | Which events notify you |
| Panel | What the menu bar number counts, stay open when clicking elsewhere, open as a window |
| Startup | Open at login |

## Developing

- `swift run` starts it straight from the source tree. Notifications and Open at login need the `.app` bundle, so they are disabled there. It uses a separate settings domain from the `.app`, so add your repos in each.
- `swift run ReviewBar --demo` (or `open build/ReviewBar.app --args --demo` for notifications) shows made-up PRs covering every Reviewing state, without calling `gh`. The next refresh (↻, or reopening the panel a minute later) plays a second step: a push, a resolved thread, a new approval and a new request. Reviews are never saved in demo mode; actions that need GitHub or Claude fail on the fake repos.
- `swift test` runs the unit tests (repo name parsing, model settings, feedback, reply and reviewing parsing from sample GitHub responses). With only the Command Line Tools, SwiftPM may not find the Swift Testing macros ("plugin for module 'TestingMacros' not found"); pass the plugin path:

  ```sh
  swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
  ```

  To shorten it, add an alias to `~/.zshrc`:

  ```sh
  alias rbtest='swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing'
  ```

- `open Package.swift` opens it in Xcode.
- Views use `@ViewState` instead of `@State`: on the macOS 27 SDK `@State` is a macro that only builds with Xcode, not with just the Command Line Tools.
- CI (GitHub Actions, macOS) builds, tests and bundles the app on every push; the zipped `.app` is attached to each run. A downloaded build is quarantined by macOS: right-click › Open the first time, or `xattr -dr com.apple.quarantine ReviewBar.app`.
- When you add or change a feature, update [docs/features.md](docs/features.md), and the At a glance list above if it's a new headline feature.

### Releases

Push a tag to build a drag-to-Applications `.dmg` (universal: Apple Silicon and Intel) and attach it to a GitHub Release:

```sh
git tag v0.1.0 && git push origin v0.1.0
```

"Run workflow" on the Release workflow builds the `.dmg` as a run artifact without making a release. Locally: `scripts/make-app.sh && scripts/make-dmg.sh`.

Without a certificate the app is ad-hoc signed: fine for your own Mac (right-click › Open the first time), but macOS may ask again for notification and Terminal permissions after each update. Signing and notarization switch on by themselves once these repository secrets exist (Settings › Secrets and variables › Actions):

| Secret | What |
|---|---|
| `MACOS_CERT_P12` | `base64 -i cert.p12`, a **Developer ID Application** certificate exported from Keychain Access |
| `MACOS_CERT_PASSWORD` | the .p12 password |
| `APPLE_API_KEY_P8` | `base64 -i AuthKey_XXXX.p8`, an App Store Connect API key (for notarization) |
| `APPLE_API_KEY_ID` | that key's ID |
| `APPLE_API_ISSUER_ID` | the issuer ID from the App Store Connect keys page |

## Contributing

The source is public so you can read it, build it and fork it. Only the maintainers can push to this repository; changes land through pull requests that a maintainer reviews. Issues and PRs from forks are welcome, but there is no promise they will be merged or answered quickly.
