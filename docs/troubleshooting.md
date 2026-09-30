# Troubleshooting

[← README](../README.md) · [Install](install.md) · [Development](development.md)

## Start with Diagnostics

**🩺 Diagnostics** (☰ menu) is a one-screen health check. Each row is ok ✓, warning ⚠, critical ✕ or
info •, and some carry a fix. **Re-check** runs it again.

| Row | What it checks | What to do |
|-----|----------------|------------|
| jq installed | The one required tool for the hooks | `brew install jq` (shown) |
| Claude Code hooks wired | Shepherd's hooks are in `~/.claude/settings.json` (N of N) | `make setup` (shown) |
| Hook scripts installed | `cc-status.sh` and `cc-approve.sh` are in `~/.claude` | `make setup` |
| Panel live | The panel heartbeat is at most 10 seconds old | Reload Hammerspoon |
| Headless approvals | ok when the gate is armed, info when it's off | ⚙ Settings → Approvals |
| Tab bridge in every VS Code window | Each window hosting a session runs the bridge, at the current version | **Developer: Reload Window** there, or `make tab-bridge` (shown) |
| Audit ledger | On or off, its size, and a warning over 50 MB | Lower `ledger.retentionDays` (shown) |
| Mailbox | How many [mailbox](automation.md#session-mailbox) messages wait, per session | They arrive at each session's next turn end or start |
| Auto-compact | `settings.json` carries the override, and every installed claude still reads it ([Auto-compact with notes](automation.md#auto-compact-with-notes)) | ⚙ Settings → Auto-compact: Save with it on, or check Claude Code's changelog (shown) |
| Live sessions | How many tiles are tracked (info) | |
| Claude Code compatibility | Its own section: whether the newest Claude Code version still has what Shepherd reads ([below](#claude-code-compatibility)) | Check Claude Code's changelog (shown) |

"(shown)" marks the fixes Diagnostics prints itself; the others are advice.

`make doctor` is a different check, run from the terminal: it reports the tools Shepherd needs (jq,
lua, node, Hammerspoon) and the optional accelerators (ripgrep, fd). It prints the install command
for each missing tool, and offers to install Hammerspoon, ripgrep and fd when run in a terminal.

## Claude Code compatibility

Shepherd reads things Claude Code never promised to keep, so an update can break a card without an
error anywhere. Once per new version it checks them, in the background, and shows the result in
Diagnostics' **Claude Code compatibility** section.

- **When:** the first time a session file (`~/.claude/sessions/<pid>.json`) carries a newer
  `version` than the last one checked. Shepherd reads the files; it runs nothing to learn the
  version. Only newer versions trigger a check, so a downgrade isn't checked again.
- **What:**

  | Check | How | Fails when |
  |---|---|---|
  | Hook events | Greps that version's binary for each event `settings.json` wires to a Shepherd script (`"PreToolUse"`, `"Stop"`, …) | The binary no longer names one: critical, the event may never fire |
  | Env vars | Greps the binary for each variable Shepherd sets (`CLAUDE_AUTOCOMPACT_PCT_OVERRIDE`, `ANTHROPIC_MODEL`, …) or reads (`CLAUDE_PROJECT_DIR`, `CLAUDE_CODE_SESSION_ID`, …) | The binary no longer names one |
  | Session files | The fields Shepherd reads: `pid`, `sessionId`, `cwd`, `name` | No session file of that version carries one |
  | Transcripts | The newest transcripts of that version: `message.usage`, `origin.kind`, `last-prompt` records, the `[Request interrupted by user` marker | A reply without `message.usage`, typed prompts without `origin.kind`, a prompt answered twice with no `last-prompt` record, or an interrupt written some other way |

- **Can't verify:** the binary is the one of exactly that version: the native install
  (`~/.local/share/claude/versions/<version>`) or the VS Code or Cursor extension of that version.
  With neither on this Mac, the hook and env rows read *can't verify*. A name the binary still
  mentions only proves it's mentioned, not that it's honoured, and the env row says so. A transcript
  fact with no evidence yet (no interrupted turn so far) reads *can't verify yet*, and is looked for
  again every 30 minutes for a day.
- **Alerts:** a failure raises a toast and a phone push (to `escalation.pushTopic`), once per
  version. A pass is quiet; so is a check that could only say *can't verify*.
- **Unreadable version:** if session files exist but none carries a readable `version`, the section
  warns *Can't tell which Claude Code version runs*: the check can't fire until that's fixed.

What to do about a failure: read Claude Code's changelog for what replaced it. A renamed hook event
goes in `settings-hooks.json`, then `make setup`. The check's last result lives in Hammerspoon's
settings (`ccCompat`); the console logs each run with a 🔍, ✅ or ⚠️ line.

## Is Shepherd running?

Shepherd has **no process of its own**. It is Lua running inside **Hammerspoon**, and
`Shepherd.app` is only a launcher, so `pgrep` or `ps` for "shepherd" finds nothing whether it's up
or not. The only signal is the panel heartbeat, `~/.claude/cc-status/.panel-alive`, which the panel
rewrites every second. Ask it:

```bash
~/.claude/cc-fleet.sh alive     # exit 0 with the heartbeat's age, exit 6 with why not
```

It's the one `cc-fleet.sh` subcommand that works outside a Claude session. When the panel is gone,
nothing waits on it: the gate steps aside to Claude Code's own permission flow, held questions go
back to the tab, and merge and batch requests say Shepherd isn't running (exit 6).

To bring the panel back: the 🐑 menu-bar icon → **Show panel**, **⌘⌥B**, or the Dock launcher. If
Hammerspoon itself isn't running, open it; Shepherd starts with it.

## Edits or an upgrade don't take effect

- Hammerspoon runs **copies** of the code in `~/.hammerspoon/`. After a `git pull`, run
  **`make setup`** (not just `make install`), then Hammerspoon → **Reload Config**
  ([Install → Upgrading](install.md#upgrading-after-a-git-pull)).
- Each VS Code window keeps the tab bridge it loaded at startup. After an upgrade, run
  **Developer: Reload Window** in windows that were already open; Diagnostics lists the ones on an
  older bridge.
- To see what the **running** panel is doing, ask Hammerspoon directly:
  `hs -c 'return type(_G.__ccDashboard)'` (needs the `hs` command-line tool, `require('hs.ipc')`).

## A tool ran without a prompt

The gate holds a tool only when it is armed, the tool is in `gate.tools`, and the panel is running.
When it can't answer (off, not gated, the panel gone, or no answer within 120 seconds), it steps
aside and **Claude Code's own permission mode decides**. In Accept edits, Auto or Bypass permissions
mode, or for a tool your Claude Code settings already allow, that can mean no prompt at all. Check
also for a policy that allowed it: the Decisions tab and the audit ledger record who decided
([Approvals and policies](approvals-and-policies.md#the-safety-model)).

## A button is greyed out or refused

- **"Shares its window"**: several Claude tabs run in one VS Code window, so Shepherd won't type into
  any of them. Jump, approvals, questions, merges and Queue still work
  ([Controls → Sessions that share a window](controls.md#sessions-that-share-a-window)).
- **Close refused**: the tab bridge couldn't pick out exactly one tab (a fresh tab still named
  "Claude Code", two tabs with the same name, or no bridge in that window). Reload the window or
  close the tab by hand.
- **Merge refused**: the merge gate is still running or queued, or it failed; the review says which
  ([Merging and batches → Merge gates](merging-and-batches.md#merge-gates-shepherd-runs-the-tests-itself)).

## Tiles look wrong

- **A card says Working long after the session stopped.** An interrupted turn fires no Stop hook, so
  its status stays `working`. Shepherd treats it as finished only when the transcript ends with Claude
  Code's *Request interrupted by user* marker. A leftover process with no tab is ended on its own
  after `tabless.autoEndMinutes` ([Controls](controls.md#sessions-with-no-tab)).
- **A duplicate tile after `/clear`.** The panel prunes it once the fresh session is live in the same
  window. **Forget tile** removes a stale orphan by hand; on a live session the tile comes back,
  because the hooks rewrite it (use **Hide tile** for that).
- **A tile never appears.** Check that the hooks are wired (Diagnostics), then capture what your
  Claude Code version sends ([Development → Confirm your hook payloads](development.md#confirm-your-hook-payloads)).

## A card flags a scheduled-tasks lock

Claude Code runs one scheduler per folder, for scheduled tasks and `/loop`. A session claims it by
writing `.claude/scheduled_tasks.lock` in its launch folder. The file holds the session's id, its pid
and when that process started. A project card shows **🔒** when that file is in one of three bad
states. Hover the chip to see which folder, why, and the fix. **Shepherd never runs the fix itself.**

- **🔒 lock dead.** The pid is gone, or it now belongs to another process that started at a
  different time (a reused pid). Claude Code takes a dead lock over the next time it schedules
  something, so this is usually harmless. A stale copy is still worth deleting. In that folder:
  `rm .claude/scheduled_tasks.lock`.
- **🔒 lock in git.** The lock is committed. Every clone and worktree checks out that copy, and each
  time Claude Code rewrites it the tree turns dirty. In that folder:
  `git rm --cached .claude/scheduled_tasks.lock`, then
  `echo '.claude/scheduled_tasks.lock' >> .gitignore`, then commit both.
- **🔒 lock held elsewhere.** A live session on another card holds this folder's lock. That happens
  when a committed lock was cloned from a repo where the session is still running. This card's
  scheduled tasks don't fire until that session ends. There's nothing to delete.

A lock whose session is on this card is healthy and shows nothing. So does a folder with no lock.
A file that doesn't parse (for example, caught mid-write) is left alone; Claude Code replaces it
itself.

How Shepherd checks:

- Every `schedLock.refreshSeconds` (default `60`, at least `30`), on its own timer and never on the
  panel's tick, Shepherd reads each launch folder's lock.
- One background `ps` (with `LC_ALL=C TZ=UTC`, as Claude Code writes the start time) checks the pids.
  Shepherd's own pid goes in as a control: if `ps` can't see Shepherd, no lock is called dead.
- `git ls-tree HEAD` checks whether the lock is committed. The answer is cached per HEAD commit, so
  git is asked again only after a new commit.
- `schedLock.enabled: false` turns the check off and clears the chips.

## Insights or History list sessions that never ran

Before 2026-09-28, running Shepherd's own test suite (`make test`, which `make setup` and the
installer run too) with the audit ledger on wrote the suite's fake events into your real ledger:
sessions in folders like `/p`, `/U/x/proj` or `/srv/…`. `tools/ledger-quarantine.sh` moves them out
of the ledger into `~/.claude/cc-ledger/quarantine/` (nothing is deleted) and says how many it moved:

```bash
tools/ledger-quarantine.sh --dry-run   # count only
tools/ledger-quarantine.sh
```

Today's file is left alone while hooks are still writing to it; run the script again tomorrow for
that one.

## Jump lands on the wrong window, or none

Focus matches the project's folder name in the VS Code window title (the default title format), then
asks the tab bridge to select the session's tab. Open the log (below) and double-click the tile: it
shows whether a title match was found. Two sessions in the same window are told apart by the tab
bridge; without it, a jump lands on the window.

## Logs

- The hook scripts log to stderr (`[cc-status]`, `[cc-approve]`, …).
- The panel logs to the Hammerspoon console **and** mirrors every line to
  `~/.claude/cc-shepherd.log`: `tail -f ~/.claude/cc-shepherd.log`. Keep the Hammerspoon console
  **closed**: an open console pops over your work whenever Hammerspoon activates, so read the file
  instead.
- A search logs `[cc-search] engine=rg …`, a folder scan `[cc-spawn] folder scan: fd …`.

## Known limits

- Typing into the VS Code extension is **best-effort**: there's no supported API to type into a
  running session, so nudges, feeds and slash commands can miss. Decision files (the gate, questions,
  merges, batches) don't have this problem, and neither does Kitty.
- The SSH status bridge is **not yet verified on real hardware**.
- The screen lock is a **soft lock**, not a security boundary ([Controls](controls.md#lock-the-screen-keep-the-agents-running)).
- Remote Control is **on by default** for spawned sessions, which widens who can type into them
  ([Providers and integrations](providers-and-integrations.md#remote-control-claudeai-and-mobile)).
