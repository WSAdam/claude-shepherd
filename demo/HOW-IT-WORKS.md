# The worktree demo — how it works

For engineers. The plain-language version is [GUIDE.md](GUIDE.md).

## The moving parts

| Part | Where | Role in the demo |
|---|---|---|
| `demo/setup.ts` | Shepherd repo | `make demo`: preflight, tidy old runs, create the run, open VS Code |
| Run repo | `~/Programming/worktree-demo-runs/worktree-demo-<stamp>/` | A fresh git repo per run (new path → VS Code restores no old tabs) |
| Driver skill | run repo `.claude/skills/worktree-demo/SKILL.md` | The playbook the driver tab follows |
| `cc-fleet.sh` | `~/.claude/` | The driver proposes the batch and asks Shepherd to open unit tabs |
| `cc-merge.sh` | `~/.claude/` | A unit asks to merge, waits for Adam, reports `done` |
| `cc-ask.sh` | `~/.claude/` (PreToolUse hook) | Holds any AskUserQuestion so Adam answers it on the Shepherd card |
| Shepherd | Hammerspoon (`claude-dashboard.lua`, `cc-core.lua`) | Shows the batch and merge reviews, owns the approvals, runs its own git checks, closes tabs |
| Tab bridge | VS Code extension (`vscode-bridge/`, ≥ 0.4.0) | Tags the tabs Shepherd opens for units and closes them after their merge — no keystrokes |
| `EnterWorktree` | Claude Code | Creates `.claude/worktrees/<slug>` and fences the unit's session inside it |

## Files the run touches

| Path | Written by | Contents |
|---|---|---|
| `~/.claude/cc-fleet/<id>.json` | driver (`cc-fleet.sh propose`) | the proposal: title, units, `mergeWhenGreen` |
| `~/.claude/cc-fleet/<id>.state.json` | **Shepherd only** | Adam's grant and each unit's session and outcome — permission is never read from the proposal |
| `~/.claude/cc-fleet/<id>.tab-<slug>.{json,answer}` | driver / Shepherd | a tab request and Shepherd's answer (the new session's name + the unit's message) |
| `~/.claude/cc-merge/<key>.json` | unit (`cc-merge.sh request`) | the merge request: branch, worktree, summary, test claim, nonce |
| `~/.claude/cc-merge/<key>.decision` | Shepherd | Adam's Merge / Not yet, bound to the request's nonce |
| `~/.claude/cc-bridge/<pid>.json` | tab bridge | each VS Code window's Claude tabs (name, unit tag) |
| `~/.claude/cc-bridge/<pid>.in/`, `.out/` | Shepherd / tab bridge | close / select / expect commands and their answers |
| `~/.claude/cc-status/<key>.json` | hooks (`cc-status.sh`) | each session's live status, which Shepherd renders |

Every answer file is **bound to a nonce** read from disk and claimed with `mv`, so a click can only
ever answer the request it was shown for.

## Sequence

```
Adam                Driver tab            cc-fleet / cc-merge      Shepherd                 Unit tabs
 │ make demo                                                                               
 │ "run the worktree demo" ─▶                                                                   
 │                   │ preflight, write .demo-batch.json                                         
 │                   │ propose (background) ──▶ <id>.json ─────────▶ card: Needs you (batch)     
 │ Approve batch ─────────────────────────────────────────────────▶ <id>.state.json (grant)     
 │                   │◀── BATCH APPROVED                                                         
 │                   │ tab --unit shout ──────▶ tab request ───────▶ expect → bridge; open tab   
 │                   │◀── session name + message ◀──────────────── identifies the new session  
 │                   │ SendMessage ───────────────────────────────────────────────────────────▶ shout: EnterWorktree
 │                   │ (same for whisper)                                                     ▶ whisper: EnterWorktree
 │                   │                                                         both edit src/greet.ts at once
 │                   │                         request ◀──────────────────────────────────────── shout: tests green
 │                   │                         <key>.json ─────────▶ own git check; card: ready to merge
 │ Merge ─────────────────────────────────────────────────────────▶ decision (nonce) ─────────▶ rebase, test, ff-merge, done
 │                   │                                               verify with git; close tab (by tag)
 │                   │                         request ◀──────────────────────────────────────── whisper: tests green
 │ Merge ─────────────────────────────────────────────────────────▶ decision ──────────────────▶ rebase → CONFLICT
 │                   │                                                         keep both sides, tests green, ff-merge, done
 │                   │                                               verify; close tab; batch finished
 │                   │ stop, npm run check, report                                            
```

## Why the conflict resolves

Both units append a function to the end of `src/greet.ts` and a test to the end of
`src/greet_test.ts`. The first merge is a plain fast-forward. The second unit rebases onto the new
main and git reports a conflict in both files: the same lines, changed two ways.

The rule every unit follows (global `CLAUDE.md`, and the run's own `CLAUDE.md`) is **the tests are
the oracle**: read both sides' tests, keep the resolution that satisfies both, and the merge is done
only when the *whole* suite passes on the merged result. Here that means keeping both functions and
both tests. If no resolution satisfied both, the unit would report `blocked` instead of picking a
side — it never deletes a test to get green.

## Safety rules the demo exercises

- **One approval per batch, in Shepherd's own state.** The driver's proposal can't grant itself
  anything; `grantMerge` is Adam's checkbox, recorded by Shepherd.
- **Merges wait for Adam** (`mergeWhenGreen: false`). Shepherd also checks each request with its
  *own* git first: the worktree is one of the repo's, on the right branch, clean, ahead of main.
- **One merge per repo at a time**, in click order — the second waits for the first.
- **No keystrokes.** Tabs are opened by URI and closed by the tab bridge; tasks arrive by
  SendMessage; answers are files.
- **A tab closes only after Shepherd verifies** with git that the merged commit is in main and the
  worktree is gone.
- **A unit's session is recorded only after Shepherd confirms it opened that tab** — a restored old
  chat that happens to resume is never mistaken for a unit.
- **Old runs go to the Trash**, never `rm -rf`, and only once their window is closed.

## Proving the result

`npm run check` in the run (`scripts/check.ts`, a copy of `demo/check.ts`) prints one ✅/❌ line
each: on main · shout on main · whisper on main · the tests pass · no unit worktree left · no unit
branch left · main is clean. Exit 0 only when all hold. `make demo-test` in the Shepherd repo
tests the setup and the check themselves.

## Troubleshooting

| You see | Why | Do |
|---|---|---|
| `make demo` lists ❌ problems | a prerequisite is missing | each line says its fix (start Hammerspoon, `make setup`, `make install`, set `CC_CODE_CLI`) |
| "This window runs an older Shepherd tab bridge" | the new window loaded an older extension | Command Palette → **Developer: Reload Window**, then "run the worktree demo" again |
| The card never shows the batch | Shepherd isn't running, or `fleet.enabled` is false | start Hammerspoon; check `~/.claude/cc-config.json` |
| A unit tab didn't open ("window wasn't in front") | focus moved while Shepherd opened it | the driver reports it; ask it to request that unit's tab again |
| A card says *merged — close its tab yourself* | the tab couldn't be matched (no tag, no unique name) | press **Close tab** on the card, or **Dismiss** |
| A unit reports **blocked** | the tests couldn't settle the conflict, or the suite stayed red | read its note; the run stops there by design |
| A permission prompt appears in a unit tab | a command outside the run's allow list | approve it in the tab (or in Shepherd); the allow list is `template/.claude/settings.json` |
| `npm run check` shows ❌ | the run didn't finish | its lines say what's left (a worktree, a branch, a missing feature) |

After a run, closing its window is all the cleanup needed; the next `make demo` moves it to the
Trash.
