# Development

[← README](../README.md) · [Troubleshooting](troubleshooting.md)

How Shepherd is built, tested and deployed. Contributor notes for Claude sessions working in this
repo live in [CLAUDE.md](../CLAUDE.md) and [context.md](../context.md); the dated history is in
[CHANGELOG.md](../CHANGELOG.md).

## How it fits together

```text
Claude Code hooks ──► cc-status.sh ──► ~/.claude/cc-status/<session>.json ──► panel (Hammerspoon)
                  ├─► cc-approve.sh ◄── <session>.decision ◄──────────────────── Approve / Deny
                  ├─► cc-ask.sh     ◄── ~/.claude/cc-ask/<key>.answer ◄──────────── answer buttons
                  └─► cc-popup.sh   (focus the editor on done / approval, when enabled)
cc-merge.sh / cc-fleet.sh ◄──► ~/.claude/cc-merge/, ~/.claude/cc-fleet/ ◄──► Merge / Approve batch
panel ──► ~/.claude/cc-bridge/<pid>.in/ ──► tab bridge (VS Code extension) ──► .out/ ──► panel
```

- [cc-status.sh](../cc-status.sh) merges each hook event into the session's JSON status file.
- [cc-approve.sh](../cc-approve.sh) is the opt-in `PreToolUse` approval gate
  ([Approvals and policies](approvals-and-policies.md)).
- [cc-ask.sh](../cc-ask.sh) holds an AskUserQuestion for the panel while Shepherd is running.
- [cc-popup.sh](../cc-popup.sh) focuses the detected editor when a session finishes or needs
  approval, if you turned that on.
- [cc-merge.sh](../cc-merge.sh) and [cc-fleet.sh](../cc-fleet.sh) are the ready-to-merge and
  batch-driving channels ([Merging and batches](merging-and-batches.md)).
- [cc-commits.sh](../cc-commits.sh) counts commits for the footer.
- [cc-lib.sh](../cc-lib.sh) holds the helpers the hooks share.
- [cc-core.lua](../cc-core.lua) is the pure logic: parsing, sorting, staleness, action selection,
  spawn specs, the ledger, insights, policies, merge and batch decisions. It has **no `hs.*`
  calls** and is unit-tested directly in plain `lua`.
- [claude-dashboard.lua](../claude-dashboard.lua) is the Hammerspoon side: it reads the status
  files, renders the panel (its HTML/CSS/JS is embedded in the file), writes the panel heartbeat
  (`~/.claude/cc-status/.panel-alive`), and wires the real effects (focus, keystrokes, files, the
  Stream Deck) into cc-core through one `FX` table.
- [vscode-bridge/](../vscode-bridge/) is the tab bridge extension: plain JS, no dependencies.

## Tests

The suite is **side-effect-free**. Run it with:

```bash
make test          # or: bash tests/run.sh
make lint          # luacheck (if installed) + luac -p + the GC-unsafe timer guard
```

It never touches your real `~/.claude/cc-status`, never fires a keystroke, never focuses a window
and never spawns a session. How that's possible:

- **Pure logic in cc-core.lua** has no `hs.*` calls and is tested directly in plain `lua`
  ([tests/core.test.lua](../tests/core.test.lua)). Panel wiring is pinned in
  [tests/ui.test.lua](../tests/ui.test.lua).
- **All effects go through one `FX` table** (focus, keystrokes, paste, decision and file writes,
  Stream Deck, spawn). Production wires it to Hammerspoon; tests pass a **recorder**
  ([tests/support/fx_recorder.lua](../tests/support/fx_recorder.lua)) that captures intent, so a
  test asserts *"would press Return on window X"* or *"would spawn in /path"* without doing it.
- **Behavioural Lua suites** load the shipped `claude-dashboard.lua` under a stubbed `hs`
  (for example [tests/smoke.test.lua](../tests/smoke.test.lua)), with `HOME` pointed at a temp dir.
- **The shell scripts** run against a throwaway `CC_STATUS_DIR`: the status writer, editor
  detection, the gate, merge requests, batches, held questions, the ledger, the installer (against
  a temp `$HOME`), the uninstaller and the bootstrap.
- **Panel JS that has to actually run** is tested with node: a test extracts the real function from
  `claude-dashboard.lua` and runs it ([tests/done-order.test.js](../tests/done-order.test.js) is the
  pattern).
- **Layout and rendering** are measured in a real headless browser: the `*.browser.test.js` suites
  load the shipped panel through [tests/support/capture-panel.lua](../tests/support/capture-panel.lua)
  and assert geometry and computed styles, not screenshots. They need Playwright (the isolate
  runner's copy, or `CC_PLAYWRIGHT=<module path>`) and skip, saying so, without it.
- **The docs** are checked too: [tests/readme.test.sh](../tests/readme.test.sh) fails if a relative
  link in the README or `docs/` is broken, or if an in-app feature (`core.FEATURES`) is missing from
  the README's feature tour.

[tests/run.sh](../tests/run.sh) is the index of every suite. The critical guards are
**mutation-checked**: reverting the fix has to turn its own test red, so an assertion can't
quietly go vacuous. Source-shape "pins" (used where a Hammerspoon-only path can't be loaded in the
harness) are called out as such.

The suite is not safe to run twice in one checkout (the installer suite shells out to the real
`make` there), so `tests/run.sh` refuses a second concurrent run and says so. Runs in different
worktrees don't share state.

Spawning is dry-run by default: the `ORCH_DRY_RUN` code constant (true) logs the launch command
without running it, and only `spawn.live` turns real launching on.

**CI.** [.github/workflows/ci.yml](../.github/workflows/ci.yml) runs `make lint` and `make test` on
`ubuntu-latest` for every push and pull request. The Playwright browser suites and the Deno demo
suite skip there; CI installs neither.

### The scenario corpus: how accurate is each detector?

Shepherd reads a card's state out of its transcript tail through six detectors: the turn's label,
*resumed* (a card that read done has started a new turn), *awaiting a tool*, *interrupted*,
*error* and *looping* (`core.scenarioVerdicts` runs them all). Unit tests feed them a few
hand-written lines; the corpus feeds them real moments.
[tests/scenario-replay.test.lua](../tests/scenario-replay.test.lua) is a table of scrubbed windows
cut from real transcripts ([tests/fixtures/transcripts/](../tests/fixtures/transcripts/README.md)),
each labelled with what was really true at that moment, judged from the raw transcript. It prints
every detector's accuracy and goes red when any verdict differs from the table. A detector that is
known to get a row wrong carries a `miss` entry saying what it answers instead: that counts against
its accuracy without failing the suite, and a detector that starts answering differently (fixed,
or wrong another way) goes red until the table is updated.

```text
Detector accuracy over 13 labelled moment(s) of real transcripts:
  turn          88%  7/8 right, 1 wrong, 5 n/a
  resumed      100%  7/7 right, 6 n/a
  ...
  looping      100%  13/13 right
```

The suite also insists every tail fixture has a row, and that every detector is seen answering
both ways. The fixtures README says how to cut a new window (`scrub.js`, which refuses any word
outside `vocabulary.txt`).

### Capturing a scenario

When a card reads wrong (Working for a session that stopped, a loop that isn't one), press
**⌖ Capture as scenario** in its detail panel, or pick it from the card's menu. Shepherd runs the
installed scrubber (`~/.claude/cc-scrub.js`, the same rules the fixtures are cut with) on the 64KB
of transcript the tick reads and writes two files to `~/.claude/cc-scenarios/`, never into a
repo:

- `<when>-<project>-<status>.jsonl`: the scrubbed window.
- `<...>.label.json`: the tail to read it back with, when the card last read done (moved onto the
  window's clock), what Shepherd's detectors said, and one `null` verdict per detector.

Fill in what was really true (a label, `true`/`false`, or `"n/a"`), then run
`lua tests/scenario-replay.test.lua --captures` to replay your labelled captures and see their
accuracy; there a disagreement is reported, not failed. To add one to the corpus, follow the
fixtures README's "From a capture to a fixture".

## Deploying changes

Hammerspoon runs the **copies** in `~/.hammerspoon/` (`init.lua` does
`dofile(... claude-dashboard.lua)`), and the hooks run from `~/.claude/`. Edits in this repo are
**not live until copied**:

```bash
make install       # copy the dashboard + core to ~/.hammerspoon, the hooks to ~/.claude, the tab bridge
make reload        # hs.reload() through the hs CLI (needs require('hs.ipc'))
make deploy        # lint + test + install + reload, in one shot
make setup         # the full installer: also re-merges the hooks into settings.json
```

A plain reload without `make install` first just re-runs the *old* copy. Changes to the hooks'
`settings.json` wiring need `make setup`. After a deploy, check the **running** code with `hs -c`,
for example `hs -c 'return type(_G.__ccDashboard.core.someNewFn)'`.

## Adding a shipped script

Every file the installers copy is one line in [SHIPPED](../SHIPPED): its name, where it goes
(`claude` for `~/.claude`, `hs` for `~/.hammerspoon`), and `hook` if Claude Code runs it as a hook.
`install.sh`, `uninstall.sh`, `make install` and the hygiene test all read that list, so a new
script is one line there and nothing else to keep in step. A new **hook** also needs:

- its wiring in [settings-hooks.json](../settings-hooks.json): an entry in an existing group, or a
  group of its own with a `matcher` if it should run for one tool or one kind of event only;
- its name in `core.OUR_HOOK_SCRIPTS` in cc-core.lua (the panel's hook inventory and Diagnostics).

The suite checks that SHIPPED's hooks, `core.OUR_HOOK_SCRIPTS` and the scripts
`settings-hooks.json` runs are the same set, and that both installers copy exactly SHIPPED's files.
`make setup` then wires the new hook into an existing install, without touching the user's own
hooks.

## Test it without Claude

Each command writes one fake event; the panel should update within a second. The status scripts
honor `CC_STATUS_DIR`, so you can rehearse in a throwaway directory:

```bash
export CC_STATUS_DIR=/tmp/cc-test
printf '{"session_id":"demo1","cwd":"'"$PWD"'","prompt_text":"Refactor the parser"}' \
  | bash ~/.claude/cc-status.sh userpromptsubmit
printf '{"session_id":"demo1","cwd":"'"$PWD"'","notification_type":"permission_prompt","message":"Allow Bash command: npm test"}' \
  | bash ~/.claude/cc-status.sh notification
printf '{"session_id":"demo1","cwd":"'"$PWD"'"}' \
  | bash ~/.claude/cc-status.sh stop
printf '{"session_id":"demo1","cwd":"'"$PWD"'"}' \
  | bash ~/.claude/cc-status.sh sessionend     # removes the tile
```

Leave `CC_STATUS_DIR` unset to point at the real `~/.claude/cc-status` the panel watches.

## Confirm your hook payloads

Field names like `prompt_text` and `notification_type` can vary slightly between Claude Code
versions. To capture exactly what your build sends, set `CC_STATUS_DEBUG=1` for the hooks (or just
once by hand) and the scripts append raw stdin to `~/.claude/cc-status/.debug.log`. Run a real
session, trigger a tool and an approval, then check that log and adjust the field paths in
[cc-status.sh](../cc-status.sh) if needed.

## Screenshots

The README's screenshots are made from fixtures, never from the live panel:

```bash
node tests/support/readme-screenshots.js      # writes docs/img/panel.png and docs/img/merge-review.png
```

It loads the shipped panel through `capture-panel.lua`, replays it in headless Chromium and feeds it
made-up sessions through the panel's own `window.ccUpdate`. Edit the fixtures in
[tests/support/readme-screenshots.js](../tests/support/readme-screenshots.js); keep every name in
them fictional, because the repo is public.

## Themes and layouts in code

To change the default layout for a fresh install, edit `DEFAULT_THEME` near the top of
[claude-dashboard.lua](../claude-dashboard.lua). Colour themes live in cc-core's
`APPEARANCE_THEMES` (each a set of token overrides over `APPEARANCE_DEFAULTS`); the stylesheet
reads CSS custom properties, so edit the tokens, not literal colours. To restyle a layout, edit
its `.theme-NAME` CSS block, or open the webview developer tools to tweak it live.

## Review tags in comments and tests

Many code comments and test names carry tags like `R1-26`, `R2-17` or `R3-18`. They reference
findings from the multi-agent bug-hunt review sweeps: `R<round>-<id>` is the `<id>`-th confirmed
finding of review round `<round>`. The authoritative "why" for each tag is the code comment next to
it: it records the non-obvious invariant (usually a concurrency or fail-closed rule) the fix
protects, so a later edit doesn't "simplify" the guard back into the bug. To trace one:
`git log --grep='R2-17'` or `grep -rn 'R2-17' .`.

The 2026-07-02 sweep (see the CHANGELOG) tracks its 30 findings as `#1`–`#30`, with regression
tests named `#<id>-pin`. The same rule applies: the comment beside each `#<id>` is the
authoritative "why", and `grep -rn '#18-pin' tests/` finds its test.
