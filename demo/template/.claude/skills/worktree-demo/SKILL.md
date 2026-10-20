---
name: worktree-demo
description: >-
  Drives Shepherd's parallel-worktree demo in this repo end to end. It proposes a 2-unit batch
  (feat/shout and feat/whisper) to Shepherd, opens both unit tabs, hands them their tasks, follows
  them through Adam's Merge clicks and the deliberate merge conflict, then verifies with
  `npm run check` and reports. Use when the user says "run the worktree demo" (or "start the
  demo") in a worktree-demo run folder.
---

# Worktree demo: the driver's playbook

You are the **driver**. Two unit tabs write the features, in parallel, each in its own worktree.
Your job: propose, open their tabs, hand them their tasks, follow them, verify, report. Adam does
three things: approves the batch once, and clicks **Merge** twice.

**Rules**
- Never edit `src/` yourself, and never approve a merge.
- Never relay Adam's answers to a unit. Units ask Adam themselves, with AskUserQuestion, and
  Shepherd shows him buttons.
- Never ask a unit to do something its own permissions would refuse.
- Never poll `ListAgents` or loop on `status`. Act when a notice or a unit's message arrives.
- At each milestone, say in one or two lines what just happened and **exactly what Adam should
  click**, using the names Shepherd shows. This run's card is labelled with this folder's name
  (`worktree-demo-…`).

## 1. Preflight

Run these one at a time; stop and tell Adam what to fix if any fails.
- `git worktree list`: only this checkout. `git status --porcelain`: empty. `git branch
  --show-current`: `main`.
- `npm test`: passes.
- Shepherd is running: `~/.claude/cc-status/.panel-alive` holds a time within 30 seconds of
  `date +%s`.
- This window's tab bridge: the `~/.claude/cc-bridge/<pid>.json` whose `folders` include this
  repo reports `version` 0.4.0 or newer.
  - If none does, or it's older, ask Adam with AskUserQuestion. Question: *"This window runs an
    older Shepherd tab bridge, so unit tabs can't close themselves. Reload it (Command Palette →
    Developer: Reload Window), then pick Reloaded."* Options: **Reloaded**, **Continue anyway**.
  - A reload restarts this chat too; after it, Adam says "run the worktree demo" again.
- Note the start time: `date +%s > .demo-start` (gitignored).

## 2. Write the batch

Write this exact file to `.demo-batch.json` (gitignored):

```json
{
  "title": "Worktree demo: shout + whisper",
  "mergeWhenGreen": false,
  "units": [
    {
      "type": "feat",
      "slug": "shout",
      "task": "At the END of src/greet.ts, add an exported function `shout(name: string): string` that returns the greeting in capitals: shout(\"Adam\") returns \"HELLO, ADAM!\". At the END of src/greet_test.ts, add a test named \"shout greets loudly\" that checks shout(\"Adam\") the same way the existing greet test does (import shout from ./greet.ts). Run `npm test` (it must pass) and commit with the message \"Add shout\"."
    },
    {
      "type": "feat",
      "slug": "whisper",
      "task": "At the END of src/greet.ts, add an exported function `whisper(name: string): string` that returns a quiet greeting in lower case: whisper(\"Adam\") returns \"(hello, adam…)\" (the last character is the ellipsis …). At the END of src/greet_test.ts, add a test named \"whisper greets quietly\" that checks whisper(\"Adam\") the same way the existing greet test does (import whisper from ./greet.ts). Run `npm test` (it must pass) and commit with the message \"Add whisper\"."
    }
  ]
}
```

## 3. Propose, then open the tabs

- Run `~/.claude/cc-fleet.sh propose --file .demo-batch.json` **in the background**
  (`run_in_background`), and end your turn. Tell Adam: *"The batch is proposed. In Shepherd, the
  worktree-demo-… card pulses **Needs you**: open it, leave **Claude may merge these when green**
  unticked, and click **Approve batch**."*
- When the command finishes, act on what it printed:
  - **`BATCH APPROVED`:** for `shout`, then `whisper`, run `~/.claude/cc-fleet.sh tab --batch <id>
    --unit <slug>` (foreground). Then SendMessage the session it prints, with the message it
    prints, verbatim, and `notify_when_idle: true`. Tell Adam both tabs are working, each in its
    own worktree (`.claude/worktrees/shout` and `.claude/worktrees/whisper`), on the same two files
    at once.
  - **`DENIED: <note>`:** report the note and stop. Nothing was opened.
  - **Exit 6 (Shepherd isn't running):** tell Adam to start Shepherd, and stop.

## 4. Follow

- Units message you when they've asked to merge, and again when they've merged or blocked.
- When one asks to merge, tell Adam: *"feat/<slug> is ready: its card pulses **Needs you** with
  *ready to merge*. Open it, look at the review, and click **Merge**."*
- The second unit to merge will rebase onto the first and **hit a conflict** in `src/greet.ts` and
  `src/greet_test.ts`. That's the point. It keeps both sides and merges once `npm test`
  passes. Say so when it happens.
- A unit that reports **blocked**: tell Adam its note, and don't fix it yourself.
- You may check `~/.claude/cc-fleet.sh status --batch <id>` when a notice arrives, never on a loop.

## 5. Finish

When both units have merged (or one is blocked):
1. `~/.claude/cc-fleet.sh stop --batch <id>`. This is harmless if the batch already ended itself.
2. `npm run check`, and show its ✅/❌ lines.
3. Report, briefly:
   - what landed (`git log --oneline -4`);
   - how the conflict was settled (both `shout` and `whisper` are in `src/greet.ts`);
   - the time taken (`date +%s` minus `.demo-start`);
   - whether both unit tabs closed themselves: no tab tagged with this batch in this window's
     `~/.claude/cc-bridge/<pid>.json`.
