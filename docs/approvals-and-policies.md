# Approvals and policies

[← README](../README.md) · [Configuration](configuration.md) · [Merging and batches](merging-and-batches.md)

How a session's requests reach you, what can answer them without you, and what never does.

## The safety model

- **The gate is opt-in.** Shepherd's approval gate ([cc-approve.sh](../cc-approve.sh)) is a
  Claude Code `PreToolUse` hook. It does nothing until it is armed (⚙ Settings → Approvals →
  **Headless approvals**, or `touch ~/.claude/cc-gate.enabled`). The one exception is the
  [always-ask commands](#always-ask-commands) (`git push`, `rm -rf`, history rewrites, publish):
  those are held for your click whether the gate is armed or not.
- **It only holds the tools in `gate.tools`** (default `Bash Write Edit MultiEdit NotebookEdit`).
  Every other tool goes through Claude Code's own permission flow, untouched. Policies apply only to
  gated tools too: an `autoDeny` rule for `WebFetch` fires only if `WebFetch` is in `gate.tools`.
- **What can approve a gated tool without you**, and only while the gate is armed:
  - an `autoAllow` pattern: the fleet `policies.patterns` when enabled, or an attached bundle (whose
    list also carries the fleet `autoAllow` patterns),
  - a bundle with `autopilot: true`, or the time-boxed **Autopilot** button,
  - `policies.approveRepeats`: the exact same request was approved by you before in this session.

  `autoDeny` is checked first and always wins. All of these are **off by default**, and none of
  them can approve an [always-ask command](#always-ask-commands).
  **Headless approvals** turns off approve-repeats, Autopilot and the fleet patterns, but an
  attached policy bundle keeps working until you detach it. Policies apply whether or not the panel
  is open.
- **When the gate can't answer**, it steps aside and returns no decision: the gate is off, the tool
  isn't gated, Shepherd wasn't running when the request came in (its heartbeat was older than 5
  seconds; a hidden panel still counts as running), or you didn't answer within 120 seconds.
  **Claude Code's own permission mode then decides.** In the default mode that is the usual prompt
  in the tab. In Accept edits, Auto or Bypass permissions mode, or for a tool your Claude Code
  settings already allow, there may be no prompt at all and the tool runs. The gate never approves
  on a timeout. An always-ask command doesn't step aside like that: it answers **ask**, so Claude
  Code's own prompt shows whatever its mode.
- **Questions are yours.** A question a session asks with AskUserQuestion is answered only by you,
  from the card or in the tab. Approve / Deny and Approve all skip it.
- **Merges are yours.** A unit merges only when you press **Merge**, or on a batch's grant you gave,
  and then only for that unit's own session and branch, after Shepherd's own git check and any merge
  gate pass ([Merging and batches](merging-and-batches.md)).
- **Answers are bound to their request.** Gate decisions, merge answers and question answers are
  files bound to a one-time nonce, so a leftover or concurrent answer can never answer a different
  request.

## Headless approvals (the gate)

Want to approve or deny from the panel with **no window switch** and still keep Claude fully gated?
Flip **Headless approvals** in ⚙ Settings → Approvals. One click arms the gate and turns off
approve-repeats, Autopilot and the fleet patterns (detach any policy bundle yourself, with the
**Policy** dropdown or the 🛡 editor). A request for a *gated* tool then turns the tile red, and Approve / Deny answer
it through a decision file: **no window focus, no keystrokes**. Claude can't run a gated tool until
you decide, or until the gate steps aside (above). This works for terminal *and* VS Code sessions.
(By hand: `touch ~/.claude/cc-gate.enabled` to arm, `rm` it to disarm.)

It is built to be safe:

- **It never waits for nobody.** The gate only starts waiting if Shepherd is running (Hammerspoon
  up and the panel heartbeat fresh; a hidden panel still counts). If Shepherd isn't running, the
  request goes straight to Claude Code's own permission flow. If Shepherd quits mid-wait, the gate
  steps aside when the timeout ends.
- **It times out gracefully.** If you don't answer within `CC_GATE_TIMEOUT` seconds (default 120),
  it steps aside rather than denying. The shipped hook registration carries a 130-second hook
  timeout so Claude Code doesn't kill the gate mid-wait; the installer migrates existing installs.
- **Decisions are request-bound.** Each gated request publishes a one-time nonce and the panel's
  Approve / Deny echoes it back, so a leftover or concurrent decision file can never answer a
  *different* request, even with several gated calls in flight on one session.
- **Reads stay fast.** Only the tools in `gate.tools` are gated; everything else runs normally.

### Deny with a reason

While a request is waiting, a **Why?** box sits beside Deny. Whatever you type goes back with the
refusal (*"Denied from the Claude Shepherd panel: use trash, not rm"*), so the session learns why and
changes course instead of just failing. It is optional, up to 500 characters, and Enter denies with
it. It travels in a sidecar file (`<session_id>.decision.note`, bound to the same request nonce as
the decision), never in the decision line itself. The audit ledger records it as the decision's
`reason`. A remote (SSH bridge) tile has no such box: a remote deny carries no note.

### Which tools are gated

- **`gate.tools`**: a space- or comma-separated list of the tools the gate holds for you, editable in
  ⚙ Settings. Emptying it (to `""` or `[]`) does **not** mean "gate nothing": it restores the
  default five and logs a warning, because a blank value can't be told apart from unset. To gate
  nothing fleet-wide, disarm the gate. To gate nothing for one session, use the per-session
  **None** setting below.
- **Per-session tool gating**: the detail panel's **Gate** dropdown (shown when **Model controls**
  is on in ⚙ Settings → Appearance) overrides `gate.tools` for one session: *Default* (the fleet
  list), *All* (everything the fleet considers risky), *None* (a trusted session: gate nothing), or
  *Custom*. It is stored per session in `~/.claude/cc-gate-tools/<key>` and read on every request, so
  a risky experiment can lock down while a trusted session runs free. It is only enforced while the
  gate is armed.

Hook environment tunables: `CC_GATE_TOOLS` (overrides `gate.tools`), `CC_GATE_TIMEOUT`
(default 120), `CC_PANEL_MAX_AGE` (default 5).

## Always-ask commands

Some commands can't be taken back. These Bash commands always wait for your click, **whatever the
gate, `gate.tools`, a session's **None** gating, Autopilot, `autoAllow`, approve-repeats or a policy
bundle says**:

- `git push`
- `rm` with both `-r` and `-f`, in any spelling (`-rf`, `-fr`, `-Rf`, `-r -f`, `--recursive --force`)
- history rewrites: `git reset --hard`, `git clean -f`, `git branch -D`,
  `git worktree remove --force`, `git checkout -- .`
- any tool's `publish` (`npm`, `deno`, `cargo`, `yarn npm`, `npx jsr` …), `gh release create`,
  `gh pr merge`

What happens to one:

- **Shepherd running:** the card holds it for **Approve / Deny**, exactly like a gated request,
  even with the gate unarmed. The request's `pending.alwaysAsk` names the rule that held it.
- **Shepherd not running, or no answer within 120 seconds:** the hook answers **ask**, so Claude
  Code shows its own permission prompt, even in Accept edits, Auto or Bypass permissions mode.
- **autoDeny still wins** while the gate is armed: a matching `autoDeny` pattern denies it.
- **An Approve is never remembered.** Approve-repeats doesn't record it, so the next one asks again.
- **The audit ledger** records the hand-off to Claude Code as `outcome: "fallback"`,
  `by: "alwaysAsk"`, with the rule as its `pattern`. Your own answer stays `by: "human"`, with the
  rule as its `pattern`.

It reads the command the way the shell does, so what counts is what actually runs:

- **Held:** `cd x && git push`, `make test; git push`, `git -C ../main push`,
  `git -c k=v --git-dir=.git push`, `sh -c "git push"`, `bash -lc '…'`, `sudo`, `env A=1`, `time`,
  `nohup`, `command`, `exec`, `xargs git push`, `find . -exec rm -rf {} \;`, `trap 'git push' EXIT`,
  `echo $(git push)`, and a heredoc fed to a shell.
- **Left alone:** `git status`, `rm -r dir`, `rm -f file`, `echo "git push"`,
  `git commit -m "git push later"`, a comment, and a heredoc that is only text (`cat <<EOF`).
- **Hidden commands are held too:** a held word behind `eval`, `$VAR`, `$(…)` or a heredoc that never
  ends (`CMD="git push"; eval "$CMD"`, `$GIT push`, `git $(echo push)`) is held as *hidden command*.

**Your own additions.** ⚙ Settings → Approvals → **Always ask** lists the built-ins (they can't be
switched off) and takes more, one per line: a command name, then words it must contain in that
order (`terraform apply`, `kubectl delete`, `docker push`; `*` and `?` work inside a word). They are
saved as `policies.alwaysAsk.patterns`. A policy bundle can add its own with `"alwaysAsk": [...]`;
a bundle only ever adds to the list, and `disableGlobal` doesn't drop the fleet's.

```json
"policies": {
  "alwaysAsk": { "patterns": ["terraform apply", "kubectl delete"] },
  "bundles": { "k8s": { "alwaysAsk": ["helm uninstall"] } }
}
```

The hook runs for every tool call, so the check is cheap for the calls that can't match: one that
isn't Bash, or a Bash command with none of the held words, is passed on without starting `jq`.

## Policies

Policies let some gated requests decide themselves. They are all off by default, configured in
`~/.claude/cc-config.json` (or ⚙ Settings → Approvals). Whenever one fires, the hook logs it to its
stderr and, when the audit ledger is on, to the ledger. The gate checks them in this order:

1. **autoDeny** patterns: deny (safety first).
2. **Bundle autopilot**: an attached bundle with `autopilot: true` allows everything it doesn't deny.
3. **Autopilot**: the session's time-boxed window allows everything.
4. **autoAllow** patterns: allow.
5. **approveRepeats**: allow a request identical to one you approved before in this session.
6. Otherwise the request goes to the panel. While approveRepeats is on, a human allow is
   remembered for it.

```json
"policies": {
  "approveRepeats": false,
  "autopilot": { "enabled": false, "minutes": 15 },
  "patterns":  { "enabled": false, "autoAllow": [], "autoDeny": [] }
}
```

- **`policies.approveRepeats`**: if you already approved the *exact* command in a session,
  auto-approve it next time. A multi-line command only matches the same multi-line command.
- **`policies.autopilot`**: the detail panel's **Autopilot** button time-boxes a session to
  auto-approve *all* its gated prompts (badge `🛫 autopilot`), expiring after `minutes`.
- **`policies.patterns`**: `autoDeny` (wins) and `autoAllow` globs, written like
  `"Bash(npm test*)"` or `"Read"`. `Tool` matches by tool name; `Tool(glob)` also matches the
  command or path against a shell glob.

> **Keep `autoAllow` tight.** A `Tool(glob)` pattern is a shell-glob match on the whole command, so
> `Bash(ls*)` also allows `ls; rm -rf /`. Prefer exact tools or anchored commands, and deny
> dangerous shapes with `autoDeny`, which always wins.

### Named policy bundles

`policies.patterns` is one fleet-wide allow/deny list. **Bundles** make those rules reusable and
per-session: define named sets under `policies.bundles`, then attach one to a session with the
detail panel's **Policy** dropdown (shown when **Model controls** is on), or fleet-wide with
`policies.attachments`. An attachment's `match` takes `project`, `group`, `providerId` and `key`,
each a glob; the first attachment that matches wins. `project` is the session's project key: its
launch folder's path encoded with dashes (`/Users/me/code/secure-api` becomes
`-Users-me-code-secure-api`), so match it with a leading `*`.

```json
"policies": {
  "patterns": { "enabled": false, "autoAllow": [], "autoDeny": [] },
  "bundles": {
    "read-only":  { "autoDeny": ["Bash", "Write", "Edit", "MultiEdit", "NotebookEdit"] },
    "no-network": { "autoDeny": ["Bash(curl*)", "Bash(wget*)", "WebFetch"] }
  },
  "attachments": [ { "match": { "project": "*secure-*" }, "bundle": "read-only" } ]
}
```

When a bundle is attached, its rules apply **even if `patterns.enabled` is false** (attaching is the
opt-in). The bundle's lists are added to the fleet patterns, or *replace* them if the bundle sets
`"disableGlobal": true`. The panel resolves each session (precedence: the per-session **Policy**
dropdown, then an attachment, then the fleet), writes the result to `~/.claude/cc-policy/<key>`, and
the gate reads it. Removing an attachment tears its enforcement down within a tick. The starter
bundles are **read-only**, **no-bash** and **no-network**. They are `autoDeny` rules, not an
allow-list, and like every policy they only act on the tools in `gate.tools`.

**The 🛡 Policy bundles editor** (☰ menu) creates, edits and deletes bundles and attachments in the
panel (the starters prefill the form) and writes them to `cc-config.json`, so you don't have to
hand-edit the JSON. It warns that bundles are enforced only while the gate is armed. Saving ⚙
Settings (or flipping Headless approvals) keeps your bundles and attachments.

## Answer questions from Shepherd

When a session needs your decision it asks with Claude Code's question tool (AskUserQuestion). With
Shepherd running, the `cc-ask.sh` hook **holds that question for Shepherd** instead of showing it in
the tab:

- **The card pulses** and says *❓ asks you: …*. It leads its project card, and you get one alert
  (plus an OS banner if approval banners are on). The hook wakes the panel itself, so the question
  reaches the card in a fraction of a second rather than on the next one-second tick.
- **The answers are buttons** in its detail panel and on its Instances row, **each with its
  explanation written out under its label**: the same text the tab shows, in full, not a hover
  tooltip. One click on a single-choice question answers it. With several parts or multi-select,
  pick per part (or type your own answer under **Other…**) and press **Send answers**. Either way
  the answer goes straight to the session as the tool's own answer: no tab to find, no keystrokes.
  The hook looks for your answer every 0.1 seconds.
- **Answer in the tab instead** hands the question back to the tab's own picker and takes you
  there. The tab's picker also takes over at once if Shepherd isn't running when the question is
  asked, and after `ask.waitSeconds` (default 900) otherwise, including when Shepherd quits while
  holding it.
- Approve / Deny (and Approve all) skip a held question: it is answered with its own buttons.

Your answer is `~/.claude/cc-ask/<key>.answer`, bound to the question it's for. The hook is wired by
`make setup`.

**It is on by default.** Switch it off in ⚙ Settings → Approvals → **"Answer questions in
Shepherd"** (or `"ask": { "enabled": false }` in `~/.claude/cc-config.json`); from the next question
on, every question goes straight to the tab, exactly as Claude Code does on its own. A config that
says nothing about `ask` leaves it on. (It was briefly opt-in on 2026-09-18, when the options showed
their descriptions only as hover tooltips and the panel froze. The freeze turned out to be a slow
transcript parse elsewhere in the panel; with that fixed and the descriptions written out, the
default went back on.)

### Questions in the tab

With the setting off (or after **Answer in the tab instead**), the panel still shows the question
and its options as buttons under the detail. On a **Kitty** session a click drives the picker
directly. In the **VS Code extension** the picker is mouse-only, so a click **jumps you to it** to
pick by hand. **Multi-select** questions, and asks with several questions, can't be driven by
synthesized keys, so Shepherd jumps you to those regardless of editor.

## Approving from anywhere

- **⌘⌥A** approves the front-most waiting approval, hands-free through the gate when it's waiting.
  Nothing is bound to Deny; use the panel.
- **Approve all** in the Fleet bar approves every waiting session currently visible (after search
  and group filters), with no confirm.
- A Stream Deck key approves a gate-waiting session on a short press and denies it on a long press
  ([Controls → Stream Deck](controls.md#stream-deck)).
- On an approval, the tile shows the **exact command** being requested (for example
  `wants: npm test -- --watch`); the detail panel adds the **Why** (the assistant's reasoning before
  the request).
