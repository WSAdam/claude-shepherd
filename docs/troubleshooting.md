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
| Live sessions | How many tiles are tracked (info) | |

"(shown)" marks the fixes Diagnostics prints itself; the others are advice.

`make doctor` is a different check, run from the terminal: it reports the tools Shepherd needs (jq,
lua, node, Hammerspoon) and the optional accelerators (ripgrep, fd). It prints the install command
for each missing tool, and offers to install Hammerspoon, ripgrep and fd when run in a terminal.

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
