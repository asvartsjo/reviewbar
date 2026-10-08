# ReviewBar features

How each part of ReviewBar works, in detail. For what it is and how to install it, see the [README](../README.md).

- [Reviewing](#reviewing)
- [Reviews](#reviews)
- [My PRs](#my-prs)
- [Crew](#crew)
- [Notifications](#notifications)
- [Settings](#settings)
- [How it works](#how-it-works)

ReviewBar refreshes every 5 minutes, and whenever you open the popover if the data is over a minute old. If one watched repo can't be read by `gh` (typo, lost access, SSO), it is named and left out so the rest keep working; it is tried again when you change Settings.

## Reviewing

Lists every open PR you review (where you are a requested reviewer, in the repos you choose, any mix of orgs and users), grouped by whose turn it is:

- **Your turn**: newly requested, re-requested, new commits since your last review, a reply in one of your threads, or the author answering in the conversation after your review or comment (a comment to someone else, like `@coderabbitai …`, doesn't count).
- **Author's turn**: nothing new since your review, or you commented in the conversation after the new commits.
- **Done**: you approved, and nothing changed or you commented on what did.

Each row shows why it is in its group, how many of the threads you opened are resolved, other reviewers' approvals and change requests, and CI. Bots are ignored. Requested rows show how long the PR has been open (orange from 3 days). ✨ / 🕘 mark a review saved in ReviewBar for this or an older version of the PR. **Review all** above the list reviews every request that doesn't have one yet. The tab count is Your turn.

A reply in a thread also counts as a review on GitHub, so replying after new commits makes them look seen.

### New activity

A blue dot marks PRs where someone else reviewed, commented or pushed since you last opened them (and, inside, the activity since then). A PR you never opened counts as new; your own comments never do. The first launch with this feature records every listed PR as seen.

### Since your review

Opening a PR you reviewed shows, freshly loaded each time:

- the new commits (or that the branch was rebased);
- what other people did since, newest first: approvals, change requests, reviews, replies in threads, PR comments, force-pushes, review requests and dismissals, draft changes (click one to open it);
- each thread you opened: open, who replied, resolved, and whether the code it points at changed (click one to open it on GitHub). Replied first, then open, then resolved, and within each by the severity icon it starts with (🚨 🔴 🟠 🟡 ❓, when a comment starts with one). A red **N blocking** counts open 🚨/🔴 ones;
- other reviewers' verdicts and open threads.

Once someone else has reviewed or commented since your review, **Summarise what happened** gives a short summary of just that.

### Muting

Right-click a row to mute it until something happens (the next review, comment or push by someone else brings it back) or for good (also no new-commits, resolved or verdict notifications). Muted PRs sit dimmed in a **Muted** section at the bottom and don't count in the tab or menu bar. A review request you never reviewed can only be muted for good; a re-request always shows, muted or not.

## Reviews

- **Review with Claude** runs `claude -p` headlessly and shows a private summary, a lean (approve / comment / request changes), and findings with `file:line`, quoted code and a question to ask the author. A running review can be cancelled. Hitting your Claude plan's usage limit shows a clear message (with the reset time when Claude Code gives one) instead of a failed review.
- **Review changes since…**: when a PR you reviewed gets new commits, review only those commits against your earlier notes (which concerns are resolved, still open, and what's new). If the branch was rebased or force-pushed the new commits can't be separated, so it falls back to the full diff with your notes, and says so. **Full review** is still there.
- **Follow up in Terminal** opens Claude Code seeded with the saved notes, the PR's reviews, review threads and conversation (your comments marked, unresolved threads first) and the current diff. It is offered for any PR with saved notes or replies.
- **Verify fixes** (in a PR's Since your review box, shown after new commits or a reply in your review threads) sends your [Verify command](#terminal) to a new Claude Code session.
- Reviews are saved locally and reload on launch, labelled with the model and effort that wrote them. A review is tied to the PR's head commit, so comments alone don't mark it stale; new commits do.

## My PRs

Lists your own open PRs (the 30 most recently updated), including ones nobody has looked at yet, grouped by whose move it is:

- **Your move**: a merge conflict, failing checks, feedback to answer, an open bot thread such as CodeRabbit's, a draft that may be ready for review, checks still running, or an approved PR with green checks ("Ready to merge"). Newest first.
- **Waiting on others**: reviewers still to look. Dismissed PRs wait here until new feedback.
- **Parked** (folded): drafts with no commit for 30+ days, and any PR you park from its right-click menu. **Unpark** brings it back. A parked PR never notifies or counts.

Feedback you haven't answered means unresolved threads where a reviewer spoke last, and approvals, change requests, review summaries or comments newer than your last commit or comment. Bots are ignored. A line on top counts both groups ("3 wait on you · 5 on others"), and the tab shows the Your move count. Only feedback from people, blockers and PRs ready to merge notify or count in the menu bar; drafts and bot threads don't. Your own drafts always show here.

Actions on a PR:

- **Summarise feedback** is offered once a reviewer has left any feedback, answered or not. It reads only comments, never the diff, so it reports what people said and what's waiting on you, not whether a fix is right.
- **Work through feedback in Terminal** opens Claude Code with all the feedback plus the diff, starting with a grouped list of what reviewers are asking for.
- With Claude Code, a PR with feedback or failing CI gets **Triage feedback** instead once you set a [Triage feedback command](#terminal), and one ready to merge gets **Merge check** (in its detail and its right-click menu). They send that command or the merge command (`can I merge {url}?`) in the checkout that has the PR's branch checked out: a worktree or your clone. ReviewBar never switches a branch: with no such checkout it copies the command instead.

## Crew

With Claude Code, the **Crew** tab lists the Claude sessions working in your watched repos, read locally with `claude agents --json` every 15 seconds. It shows both terminal sessions and agent view (`claude --bg`) ones.

- Sessions waiting on you come first ("needs you": a question in the terminal, or a blocked background session). Sessions at their prompt fold under **Idle**, since one can live on with no visible window. The tab shows how many sessions are active (not idle).
- Each row shows the PR it works on when its folder tells (a worktree on your PR's branch, or a review worktree) and where it runs (iTerm2, Terminal, VS Code), found from its parent processes.
- Click an agent view session to open it with `claude attach`. Click a terminal session for its PR, or to bring it to the front (also right-click › **Show session**): its tab in iTerm2 or Terminal, or VS Code's window for its folder for a session in the Claude Code extension.
- Right-click › **Stop session** stops either kind and keeps its conversation: agent view with `claude stop` (`claude attach` resumes it), terminal by ending its `claude` process (`claude --resume` reopens it; a working one asks first).
- A PR with a session shows a **Claude needs you** or **Claude working** badge, in My PRs and in Reviewing.
- Before any terminal button opens a session on a PR that already has one (in any state, idle included), or that ReviewBar opened a session on in the last minute, it asks first: two sessions in one checkout overwrite each other's edits.
- When a session starts waiting on you, a **Claude needs you** notification fires (agent view itself only notifies while it's open), and sessions waiting on you add to the menu bar number. Both can be turned off in Settings.

Agent view is a research preview: if its output changes, the tab stays empty.

## Notifications

ReviewBar notifies you about:

- new review requests (a request on a PR you already reviewed says re-requested);
- replies on your review threads;
- feedback on your PRs;
- checks turning green on your PRs that aren't ready to merge yet (a push whose checks finish between two refreshes counts too; parked PRs and PRs without checks stay quiet; it never counts in the menu bar);
- on PRs you reviewed: new commits after your review, all your threads resolved, and other reviewers approving or requesting changes.

Each kind can be turned off in Settings. Clicking a notification opens the PR. New commits don't create a GitHub notification, so they show up with the 5-minute refresh; that notification has a **Verify fixes** button (hover over it, or use the Alerts style) that starts the Verify session when a Verify command and a terminal are set.

Several events on one PR in the same refresh (say a re-request and new commits) become one notification, and more than three PRs at once become one summary. The first refresh after launch only sets a baseline, so starting the app doesn't flood you.

## Settings

### AI tool

Switches between Claude Code and Codex.

- **Claude**: pick a model and effort for anything that reads code (Review with Claude, every Terminal session; default Opus), and a separate pair for **Summarise feedback** (default Sonnet, low effort). Models are Claude Code aliases, so they follow the latest release in each family. "Default" passes no model flag, so Claude Code's own settings apply. Terminal sessions get the feedback summary as a starting point together with the full comments and diff.
- **Codex**: type a model name (e.g. `gpt-5.5`) or leave it empty for your Codex config, and pick a reasoning effort. `OPENAI_API_KEY` is unset so it uses your ChatGPT login, and headless reviews run with `codex exec --sandbox read-only`.

### Review prompt

See and edit how reviews are written and how suggested comments are worded. It's used by every review and re-review (Claude and Codex), and by new terminal reviews unless a Review command is set. *Full prompt* shows the whole prompt; the rules and output format around your text stay fixed, because ReviewBar reads the verdict and findings from them. **Reset to built-in** (or an empty box) brings back the default.

### Terminal

- **Terminal app**: open Claude Code sessions in Terminal, iTerm2, Ghostty, WezTerm, kitty or Alacritty. Only installed ones are listed. **Automatic** (the default) picks the first installed of Ghostty, iTerm2, WezTerm, kitty, Alacritty, then Terminal. For anything else (Warp, …) choose **Copy command** and paste it into your terminal. When Claude exits you are left at a normal shell prompt.
- **Review command**: the first message of a new review there. Empty (the default) uses the built-in review prompt; enter e.g. `/pr-review {url}` to run your own skill or command. Codex always uses the built-in one.
- **Verify command**: sent by *Verify fixes*. By default it asks Claude to check each of your GitHub threads against the commits since your review; leave it empty to hide the button (Claude only).
- **Triage feedback command**: sent by *Triage feedback* on your own PRs with feedback or failing CI. Empty by default, so those PRs get the built-in Work through feedback prompt; enter e.g. `/pr-feedback {url}` to run your own skill.
- **Put PR worktrees next to the clone** keeps them in `<clone>-worktrees/pr-<N>` instead of ReviewBar's own folder. See [Local clones and worktrees](#local-clones-and-worktrees).

### Pull requests

- **Include draft PRs** (on by default): turn off to hide other people's drafts from Reviewing. Your own drafts always show in My PRs.

### Notifications

Turn each kind on or off (see [Notifications](#notifications)), including Claude needs you.

### Panel

- **Menu bar number**: pick what the number counts: review requests (awaiting your review), new commits or replies on PRs you reviewed, feedback on your PRs, and mentions. All are on by default. A PR counts once even when it's in several. PRs muted in Reviewing don't count as requests or activity, but a mention still counts.
- **Stay open when clicking elsewhere** (off by default) keeps the popover up while you work in other apps; close it with the menu bar icon or Esc.
- **Open as a window** (off by default) opens a normal window instead of the popup: move and resize it (at least 480×580), and it stays open until you close it. It remembers its position and size. Clicking the menu bar icon brings it to the front. It isn't in the Dock or ⌘-Tab.

### Startup

- **Open at login**.

## How it works

- Commands run through an interactive login zsh so `PATH` matches your Terminal.
- `ANTHROPIC_API_KEY` and `ANTHROPIC_AUTH_TOKEN` are unset for every `claude` call so the subscription is used, never API billing.
- Reviews are stored in `~/Library/Application Support/ReviewBar/` (`reviews.json` plus one `.md` per review).
- Diffs are capped at 250 KB. Terminal follow-ups refuse prompts over 800 KB (macOS argument limit).

### Headless review safety

Headless reviews never get a shell or MCP servers (`--strict-mcp-config`) and run no hooks (`disableAllHooks`). They still follow the repo's CLAUDE.md and `.claude/rules/` and your own `~/.claude/CLAUDE.md`, so a PR's own edits to those files can steer its review.

When the PR's checkout has its own `.claude/settings.json` or `settings.local.json`, which could redirect the API (`env`) or run a command (`apiKeyHelper`), the review loads your user settings only (`--setting-sources user`). That drops the project's CLAUDE.md and rules too, and the review says so under the verdict.

### Local clones and worktrees

When the repo has a local clone (chosen in Settings, or found under `~/Projects`, `~/Developer`, …), the review runs in a worktree of the PR's head commit with read-only tools (`Read,Grep,Glob`; Codex: `--sandbox read-only --cd <worktree>`), so it can check callers and conventions instead of asking the author. Without a clone it gets no tools (`--tools ''`) and only sees the diff. This needs a recent Claude Code (`claude update`).

Opening a PR again moves its worktree to the new head, unless it has local changes or commits the PR doesn't have yet.

Once a day ReviewBar removes the worktrees it made for PRs that are now merged or closed, and only when nothing would be lost: no uncommitted or untracked files (ignored ones such as a copied `vendor/` don't count) and no commit that isn't on GitHub. Your own worktrees and branches are never touched.
