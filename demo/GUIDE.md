# The worktree demo — a plain-language guide

## What this shows

Normally, if you ask one assistant to do two jobs on the same project, it does them one after the
other. This demo has **two Claude assistants work on the same project at the same time**, each on its
own job, without getting in each other's way — and then brings both jobs together safely, even
though they changed the very same lines.

It takes about ten minutes. You make three clicks.

## A few words first

| Word | What it means here |
|---|---|
| **Project** (or *repo*) | A folder of files whose history is tracked, so every change is recorded and can be undone. |
| **main** | The official, finished version of the project. |
| **Worktree** | A second desk with its own copy of the project's files. Work done at one desk doesn't disturb the other; nothing reaches *main* until it's merged. |
| **Unit** | One job, done by one assistant, at its own desk (worktree). |
| **Merge** | Bringing a finished job into *main*. |
| **Conflict** | Two jobs changed the same lines. Someone has to decide how to combine them. |
| **Tests** | Small automatic checks that prove the project still works. Here they decide how a conflict is combined: the combination must pass *both* jobs' tests. |
| **Shepherd** | The panel on your screen that watches every Claude session and asks you when one needs you. |
| **Driver** | The Claude tab you talk to. It hands out the jobs and keeps you posted; it doesn't do the jobs itself. |

## The two jobs

The demo project is a tiny app that says *Hello, Adam!*. The two jobs are:

- **shout** — add a loud greeting: *HELLO, ADAM!*
- **whisper** — add a quiet one: *(hello, adam…)*

Both are added to the end of the same file — on purpose, so you see a conflict get resolved.

## Step by step

1. **Start a fresh run.** In a terminal, in the Shepherd folder, type `make demo`.
   It checks that Shepherd and its helpers are ready, builds a fresh copy of the tiny app, and opens
   it in a **new VS Code window** named *worktree-demo-* followed by the date and time.

2. **Tell Claude to begin.** In that new window, open a Claude tab and type **run the worktree demo**.
   From now on that tab is the *driver*: it tells you what's happening and what to click.

3. **Approve the plan — click 1.** In Shepherd, the *worktree-demo-…* card turns red and pulses
   **Needs you**. Open it: it lists the two jobs. Leave **"Claude may merge these when green"**
   unticked (you want to approve each merge yourself) and click **Approve batch**.

4. **Watch two assistants work at once.** Two new Claude tabs open in the window by themselves.
   Each gets its job and moves to its own desk (worktree). They work **at the same time**, on the
   same file, without seeing each other's half-finished changes. Each runs the tests when done.

5. **Approve the first merge — click 2.** When a job is finished and its tests pass, its card pulses
   **Needs you** with *ready to merge*. Open it: you can see exactly what changed. Click **Merge**.
   It lands on *main*, and its tab closes by itself.

6. **Approve the second merge — click 3.** The other job's card does the same. Click **Merge**.
   This one finds that *main* has moved on — the first job changed the same lines — so it hits a
   **conflict**. It combines the two by keeping both greetings and both tests, runs the tests, and
   only lands when they all pass. Its tab closes by itself too.

7. **See the result.** The driver runs `npm run check` and reports:
   ✅ shout is on main, ✅ whisper is on main, ✅ the tests pass, ✅ no desks or leftover jobs remain.

## What success looks like

- Two jobs were done **at the same time** in one project.
- Both are on *main*, and every test passes.
- The conflict was settled by the tests, not by guesswork.
- Nothing is left lying around: no extra desks, no leftover jobs, no stray tabs.
- You never typed into the assistants' tabs — three clicks in Shepherd was all.

## If something doesn't go to plan

The driver tells you in its tab, and Shepherd shows a red card with a button. The most common one:

- *"This window runs an older Shepherd tab bridge"* — the new window needs a one-time reload
  (Command Palette → **Developer: Reload Window**). Then say **run the worktree demo** again.

For anything else, see the troubleshooting table in [HOW-IT-WORKS.md](HOW-IT-WORKS.md#troubleshooting).

To run it again, just type `make demo` again: every run is brand new, and old runs go to the
Trash once you've closed their windows.
