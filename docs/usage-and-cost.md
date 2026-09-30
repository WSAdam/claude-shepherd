# Usage, cost and history

[← README](../README.md) · [Fleet](fleet.md) · [Configuration](configuration.md)

Token use, plan limits, cost estimates, commit counts, and the audit ledger with the views built on
it. None of this **spends model tokens**, and all of it except the plan-window bars (one metadata
call) is read locally.

## Token usage

Shepherd reads token usage straight from Claude Code's **local transcript files**
(`~/.claude/projects/<project>/<session>.jsonl`), which log every turn's `usage`.

### Context-fullness bar

Every tile in the Cards and Contrast layouts shows the last turn's prompt size (input plus cache)
divided by the model's context window, with the percentage on the bar. It tells you which session
to `/compact`.

- The window is **model-aware**: 1M for Opus 4.x and Sonnet 4.x model ids (their window on Claude
  Code), and for any Opus or Sonnet session set to Claude Code's 1M-context option (a model ending
  in `[1m]`, like `opus[1m]`). Transcripts only record the bare model id, so the option is read
  where Claude Code reads it: the session's own model, then the project's
  `.claude/settings.local.json` and `settings.json`, then `~/.claude/settings.json`. A `/model`
  switch mid-session wins over all of them: the transcript records the switch ("Set model to
  …"), and the bar follows the newest one, to `[1m]` or away from it, on the next usage pass.
  Otherwise 200k. A provider's `contextLimit` overrides it, and a prompt larger than the assumed window
  rounds it up to the next tier (200k / 1M / 2M), so a session never reads a false 100%.
- To match Claude Code's own "% until auto-compact", the bar divides by
  `window × context.autoCompactFraction` (default `0.92`; the exact threshold is undocumented, so
  this is a close approximation).
- The colour steps through **7 bands**: calm below 50%, a new colour every 10% (50/60/70/80/90), and
  a distinct **critical** band for the last 5%.
- It is computed on the 60-second usage pass (and live on the one-second loop for active sessions),
  so it shows on finished tiles too.

### Fleet total

The footer under the grid shows cumulative tokens across active sessions. The headline **excludes
cache reads** (input + output + cache creation), because cache reads dominate the gross count but
aren't how the plan is metered; the gross figure is on hover. It is recomputed every 60 seconds
(reading only new bytes) and on **Update now**. Each API message counts once (Claude Code repeats
its usage on every record it writes for that message), and a session's subagent transcripts count
toward its total, so the figures match Claude Code's own cost records.

The totals **survive a reload**. Shepherd saves where it stopped reading each transcript, with the
totals so far, the last 7 days of turns (for the local window bars) and the message ids it has
already counted, to `~/.claude/cc-usage-state.json`: at most every 5 minutes, and when Hammerspoon
quits or reloads. On startup it resumes each transcript from its saved position, so it reads only
what was written while it was down instead of re-reading every transcript from the start. A
transcript that is gone or now shorter than its saved position is read again from the start. An
unreadable file, or one from another version, is ignored and every transcript is read afresh.
`uninstall.sh --purge` removes it.

It also shows an **`~$X est.`** API-equivalent dollar figure from a per-model price table
(`core.PRICING`, cache-aware, at Anthropic list prices). Your subscription is flat-rate, so this is
an estimate. Gateway and local models have unknown prices and are left out.

| Family | Input | Output | Cache write (5 min) | Cache write (1 hour) | Cache read |
|--------|------:|-------:|--------------------:|---------------------:|-----------:|
| opus   | $5    | $25    | $6.25               | $10                  | $0.50      |
| sonnet | $3    | $15    | $3.75               | $6                   | $0.30      |
| haiku  | $1    | $5     | $1.25               | $2                   | $0.10      |
| fable  | $10   | $50    | $12.50              | $20                  | $1.00      |

Dollars per million tokens. Claude Code's main thread writes 1-hour cache entries; each write is
priced at its own rate. Override any of them with
`pricing.<family>.{input,output,cacheWrite,cacheWrite1h,cacheRead}`.

### Plan window bars

Your real **session (5h)** and **weekly** utilization, matching `claude.ai/settings/usage` and
Claude Code's `/usage`, with reset times. Below them, a **per-model weekly line** for any model the
endpoint meters separately (`Weekly · Sonnet`, `Weekly · Fable`). A per-model line appears **only when
that model is actually being metered**, so the footer never shows an empty `0%` line.

The bars come from Anthropic's OAuth usage endpoint (`/api/oauth/usage`) using your existing Claude
Code login token (macOS Keychain or `CLAUDE_CODE_OAUTH_TOKEN`). **This is a metadata call; it spends
no model tokens.** It is polled at most every **180 seconds**, sends the token only to
`api.anthropic.com` over HTTPS, and never logs it. If the token is missing or expired, or the
endpoint is unreachable, the bars **fall back** to a labeled local approximation (rolling 5h and 7d
token sums from your Anthropic-session transcripts).

### Plan-limit warnings

On by default. When any plan window crosses **90%**, Shepherd raises one macOS notification and
(when the ledger is on) records a `usage_limit` row in it, so a long unattended run doesn't die on a cap with
no warning. It covers the session bar, the weekly bar and every per-model weekly line. It is
passive: no keystrokes, no session actions, no model tokens.

Alerts are **once per whole percentage point**: crossing 90% warns, then 91%, then 92%, up to 100%.
A bar sitting still stays quiet (drift within a point is silent), and a jump doesn't backfill:
straight from 90% to 95% warns once, for 95%. The window re-arms when it resets.

```jsonc
"usage": {
  "limitAlerts": {
    "enabled": true,      // false turns the warnings off
    "thresholdPct": 90    // first warning at this %, then one per point above it
  }
}
```

Click a row in the ledger's 🔔 **Alerts** view for the detail: which window, the exact percentage,
the threshold that tripped it, and when that window resets.

### Honest limits

- Plan usage is shown in **tokens and percentages**; the dollar figures are estimates, because the
  subscription is flat-rate.
- For **gateway** sessions (Gemini, OpenAI through LiteLLM) cumulative usage still appears (whatever
  the gateway reports; cache tokens are about 0). Set a per-provider `contextLimit` (for example
  Gemini → `1000000`) so the fullness bar uses the right window.
- The plan window percentages reflect your **Anthropic** account only; gateway and local tokens
  don't count against it. Local servers that omit `usage` show no bar.

## Commits today and this week

Under the plan bars: `Today  4 commits · +312 −40` and
`This week  25 commits · +4.3k −174 · ↑8 vs last wk`, with a Mon–Sun bar per day (today outlined).
The pace compares this week with the same stretch of last week (its Monday up to exactly 7 days
ago). Click either line for the drawer: each project's today and week with its own day bars (click a
project for its commits) and the latest commits across all of them.

- It counts from **local git** with `~/.claude/cc-commits.sh`, so unpushed work and worktree branches
  count, and a commit is dated by when it was written (a rebased unit still lands on its real day).
- **Whose commits**: each repo's `git config user.email` plus `commits.authorEmails`. Nothing about
  the user is hardcoded, so every install counts its own user.
- **Which repos**: every repo a Claude session worked in during the last two weeks (from the
  transcripts in `~/.claude/projects`, removed worktrees included). A commit counts once across
  clones and rebased copies; lockfiles and minified or map files don't count toward lines.
- **Which session made it**: each commit in the drawer ends with the session that made it: the
  tile's name while that session is open (click it for its **Transcript** tab), or the session id,
  dimmed, once it has ended. Nothing goes in the commit message. `git commit` prints
  `[branch sha] subject` into the session's Bash result, and Shepherd matches that line to the
  commit by subject and author time (the record at most 15 minutes after the commit, the nearest
  one winning), so a rebased commit keeps its link. `git commit -q` prints nothing, so Shepherd
  also reads the subject from the `git commit` command itself: a heredoc's first line, a `-m`
  message, or the first line of a `-F` file that still exists (that record comes up to 15 minutes
  *before* the commit). A subagent's commit belongs to its parent session. Commits made outside
  Claude show no session. The scan uses
  ripgrep when it's installed (well under a second over two weeks of transcripts) and grep
  otherwise (a few seconds, still in the background).
- git runs in the background every 5 minutes, on **Update now**, and when the drawer opens (if the
  last count is over a minute old), never on the panel's tick. `commits.enabled: false` hides it; the other `commits.*` keys are documented in
  [cc-config.example.json](../cc-config.example.json).

## Cost and tokens

**💰 Cost & tokens** (☰ menu) needs the audit ledger. It reads the per-session running totals the
ledger records (a `usage_snapshot` at most every `ledger.usageSnapshotMinutes`, default 10, while
`ledger.usageSnapshots` is on) and shows:

- three totals: **estimated cost to date**, **tokens used** and **sessions tracked**;
- a **daily chart of the last 14 days** (by local day), in dollars when any day has a cost, else in
  tokens;
- a **By session** table of the top 12 sessions with their tokens and estimated cost.

The dollar figures use the same `core.PRICING` table as the footer, at Anthropic list prices.
**Refresh** re-reads the ledger.

## Where the time went

**⏱ Time** opens it for one session (the detail panel's action row) or for a whole project (the
header of a card's **Instances** view: every session on the card, over the last `timeLost.days`,
default 7). It starts with plain sentences, most costly first, for example:

- *38m waiting on you, 12m of it on one approval*
- *30m stopped at a usage limit* · *20m stalled with no progress (2 stalls)*
- *1m 30s in errors (runtime errors)* · *10s retrying the API (1 retry)* · *3m compacting (1 compaction)*
- *2 turns took 11m; 1 was interrupted*
- *77% of input came from the cache* · *Cache writes: 16.0k at 5 minutes, 20.0k at 1 hour (~$0.30)*
- *Subagents used 44% of the tokens (1 subagent)* · *Sessions ended: 2 cleared, 1 exited*

Then five totals (**lost**, **waiting on you**, **at usage limits**, **stalled**, **errors & retries**)
and a table of the waits by kind. *Lost* is waiting on you + usage limits + stalls + the larger of
error time and API retry time (the ledger and the transcript see the same outage from two sides,
so they are never added).

Two sources feed it:

- **The audit ledger** (needs `ledger.enabled`). Shepherd writes one event per episode, when it
  ends: `waited` with a `source` and `seconds` -- a wait on you is exactly what the card's *Needs
  you* says (a permission prompt, a question, a merge review, a batch proposal), plus `limit` for
  a usage limit -- `hung_end` when a stalled session moves again, and `error_end` with the error's
  `reason` when it recovers. A session that ends mid-wait ends the wait there. `session_start`
  now carries Claude Code's `source` (startup, resume, clear, compact) and `session_end` its
  `reason` (clear, logout, prompt_input_exit, ...) and a `projectKey`.
- **The transcripts**, read in the background (never on the panel's tick) every
  `timeLost.refreshSeconds` (default 120) and when the view opens: each live session's transcript
  and its subagents'. A pass reads only what changed -- a transcript whose size and mtime haven't
  moved isn't read, one that grew is read from where the last pass stopped -- at most 2 MB per
  transcript and 8 MB per pass, the rest in the passes after. From them: turns (prompt to Stop) and
  how each ended (done, interrupted, an API error, never finished), API retry episodes, compaction
  time, and tokens -- cache reads, 5-minute and 1-hour cache writes priced like the footer, the
  main transcript against its subagents. Nothing is saved; after a reload the index is rebuilt.

`timeLost.enabled: false` stops the background reads.

## The audit ledger

An optional, append-only JSONL record at `~/.claude/cc-ledger/YYYY-MM-DD.jsonl`, one event per line:
session start and end, prompts, tool requests, gate **decisions** with who decided (`autoDeny`,
`autoAllow`, `autopilot`, `approveRepeats`, `bundle:<name>`, `human`, or `timeout-fallback`), mode,
model and effort changes, nudges, clears, compacts, spawns, relabels and automatic actions. It is
**off in code and on in the installer's default settings** (`ledger.enabled`), and it is the data
source for everything below.

The **📜 Audit ledger** view (☰ menu) has **Rows** and **Timeline** tabs, filters by session, type and
date, a per-row **redact** (past days only), and **Export** and **Purge…** for the filtered rows.
Retention is cleaned about hourly by
`ledger.retentionDays` / `ledger.maxTotalMB`. **Review activity** sends the current slice to the
selected session as a read-only governance prompt (assess risky or odd actions, never edit).

### Fleet insights

**📊 Fleet insights** (☰ menu) is a read-only aggregate of the ledger: turns per session,
approval and denial rates, decision provenance, the most active sessions, and the total time the
fleet spent **blocked on you** (the gap from each request to its human or timeout answer, capped by
`insights.maxBlockSeconds` so an overnight idle isn't counted). **Trends — last 24h** adds four
hourly sparklines: time blocked on you, fleet activity, active sessions and denial rate. It is
always available, and shows zeros until the ledger is on.

With `insights.hostStats` on, a **Host** strip at the top shows CPU, memory, disk, uptime and load,
plus how long the whole fleet has been idle, and notes when the machine is under pressure
(`insights.hostPressure.{cpu,mem,disk}`, default 90%).

### Notifications

**🔔 Notifications** (☰ menu, with an unseen count on the ☰ button) opens the ledger's **Alerts** tab:
what happened while you were away over the last `notifications.days` (default 7): escalations, stall
warnings, auto-respawns, auto-continues, plan-limit warnings, and every gate decision **not made by
a human**. Opening it marks everything seen and highlights what's new. If you've set
`ledger.captureTypes`, include `escalation`, `hung`, `auto_respawn`, `auto_continue`, `usage_limit`
and `decision`.

### Shift report

**📋 Shift report** (☰ menu and the ledger's **Shift** tab, shown while the ledger is on) is a
one-click account of **what the fleet did over a window**: **Since opened** (since you launched
Shepherd), **Last 8h** or **Last 24h**. It rolls up sessions active, prompts, approvals (allow or deny
and who decided), automatic actions (respawns, continues, drains, routed feeds), escalations and
stalls, the time you were the bottleneck, and a per-project breakdown; **Copy** puts it on the
clipboard. It reports *operations*, not outcomes: there's deliberately no "what shipped" line,
because a prompt is an instruction and the ledger has no CI ground truth.

### Session history

The ledger's **🗂 History** tab lists every session the ledger has seen, with its turns, tool calls,
events and last activity. Filter by name or folder, sort **Recent / Oldest / Most active**, and
narrow to **this workspace** or **pinned only**; ★-pin the projects you care about.
Multi-select rows and **Delete selected** purges those sessions' recorded history through the same
confirmed purge the Purge button uses. It never deletes Claude Code's own transcripts.

### Run score

The detail panel's **Score** button rates the selected session 0–100 from the ledger: it starts at
100 and subtracts 18 per API error, 6 per denied tool, 12 per loop episode and 14 per forced respawn.
It shows a ⚠ when recent sessions trend down, and a small sparkline of the trend. Those weights are
the defaults: `"score": { "weights": { "error": 18, "deny": 6, "loop": 12, "respawn": 14 } }` in
`~/.claude/cc-config.json` (hand-edit only) changes any of them, for the Score button, its trend
and the A/B compare's scores alike.

### Storage

⚙ Settings → Observability → **Measure storage** shows how much disk Shepherd's own state uses: the
audit ledger, task queues, session status and the `cc-*.json` state files, never Claude Code's
transcripts. Trim old ledger days with the retention setting, and delete a session's recorded
history from the 🗂 History tab.
