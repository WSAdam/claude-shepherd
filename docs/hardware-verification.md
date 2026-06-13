# Hardware verification runbook

Two Shepherd features ship with their **pure logic unit-tested** but cannot be fully
verified by the agent — they need real hardware: a **Kitty** terminal box and a **second
machine reachable over SSH**. This runbook is the checklist to run on that hardware. Each
item lists the command, what to watch, and how to fix it if the observed token/flag is off.

Nothing here is "done" until you've run it on the real boxes. Until then these stay in
`todos.md` under **needs-hardware (runbook ready)**.

---

## A. Kitty `kitty @` send-key tokens

Shepherd drives a Kitty-hosted session headlessly with `kitty @ send-key` (focus / approve /
deny / nudge / close / answer / mode). `kitty @ send-key` **fails silently** on an unknown
key token, so a wrong token = a no-op with no error. The tokens live in
`core.KITTY_KEY` (cc-core.lua) and the picker nav in `core.answerKeys`.

### A1. Remote control is actually on
```bash
kitty @ ls >/dev/null && echo "remote control OK" || echo "remote control OFF"
```
- **Expect:** `remote control OK`. If OFF, the spawned window lacks `allow_remote_control`
  (check `spawn.kittyRemote`) or the global `kitty.conf` wasn't updated — run **⚙ → Enable
  Kitty remote control now**, then restart Kitty.

### A2. Each send-key token reaches the TUI
Spawn a Claude session in Kitty, then from another terminal (match the window):
```bash
# replace --match with the real selector Shepherd uses (title/socket)
kitty @ send-key --match title:claude enter
kitty @ send-key --match title:claude esc
kitty @ send-key --match title:claude down
kitty @ send-key --match title:claude tab
```
- **Expect:** each visibly acts in the session (Enter submits, Esc cancels, Down moves a
  selection, Tab/Shift+Tab cycles permission mode).
- **Fix:** if a token is inert, it's the wrong glfw name. Update `core.KITTY_KEY`
  (`["return"]="enter"`, `escape="esc"`, `down`, `up`, `tab`) to the name that works, add a
  unit test, re-deploy.

### A3. AskUserQuestion picker navigation
Trigger an AskUserQuestion in the session (a tool that asks a multi-option question). Have
Shepherd answer option N via the panel.
- **Expect:** `core.answerKeys(N)` = Down × (N-1) + Enter lands on the right option.
- **Fix:** if it lands one off, adjust the offset in `core.answerKeys` (and confirm
  `core.askIsMulti` correctly routes multi-select to jump-only).

---

## B. SSH status bridge (8-point checklist)

The bridge mirrors a remote box's `~/.claude/cc-status/` into the panel as `host:`-namespaced
**headless-only** tiles, and routes Approve/Deny back over SSH (nonce-bound). Enable it with a
provider that declares `ssh:{host,user}` + `bridge.enabled`. Pure layer:
`core.sshHosts` / `rsyncArgv` / `parseMirrorList` / `decisionSshArgv` / `namespaceKey`.

1. **Remote install + headless shape.** On the remote box: clone + `make install`. Then:
   ```bash
   ls ~/.claude/cc-status/*.json && jq '{editor, kitty_window_id}' ~/.claude/cc-status/*.json
   ```
   - **Expect:** files exist with `editor:"kitty"` (or terminal) and **no** `kitty_window_id`
     (`ssh -t` forwards TERM but not `KITTY_WINDOW_ID`). This "remote = headless-only"
     assumption is what the whole design rests on. If a `kitty_window_id` shows up, revisit
     `core.remoteActionAllowed`.

2. **rsync round-trip + `--delete`, incl. openrsync.** Time one pull and confirm deletes
   propagate. Sequoia+ ships **openrsync**, not stock rsync:
   ```bash
   rsync --version | head -1   # note: openrsync vs rsync
   time rsync -az --delete --timeout=5 -e "ssh -oBatchMode=yes -oConnectTimeout=3" \
     user@host:.claude/cc-status/ /tmp/mirror-test/
   ```
   - **Expect:** completes in well under `bridge.intervalSeconds`; a file removed on the
     remote disappears from `/tmp/mirror-test/` next pull. Verify the `core.rsyncArgv` flag
     set is accepted by **both** rsync and openrsync.

3. **Decision round-trip.** Approve a mirrored approval tile in the panel.
   - **Expect:** the remote `cc-approve.sh` consumes the nonce-bound `.decision` file within
     its poll window, the nonce matches, and the **native prompt never fires** on the remote.

4. **SSH non-interactivity / dead host.** Confirm `BatchMode=yes` + key/agent auth (no
   password prompt). Then pull the remote's network:
   - **Expect:** the sync task exits non-zero, `running` clears, no timer pile-up, **one** log
     line per outage (not a spin).

5. **Clock skew.** Compare `date +%s` on both boxes.
   - **Expect:** within a few seconds. If larger, raise `bridge.staleSlackSeconds` so remote
     tiles don't flap to stale from skew alone.

6. **`bridge.keystrokes` experiment.** Does Claude Code's title escape reach the *local*
   kitty/Terminal window title over `ssh -t`, and does `focusProject` match it?
   - **If yes:** nudge/stop/clear/compact can be un-greyed behind the `bridge.keystrokes`
     flag (and remote tiles become routing targets — see the deferred routing follow-up).

7. **Remote SessionEnd.** End a remote session.
   - **Expect:** its mirror file is deleted on the next sync → the tile disappears (no local
     prune needed).

8. **Spawn-then-appear latency.** Spawn via an SSH provider.
   - **Expect:** the tile shows within ~2× `bridge.intervalSeconds`.

---

## Reporting

For any token/flag that's off, capture the command + observed output, fix the value in
`cc-core.lua`, add a unit test that pins the corrected value, and run `make test` before
`make deploy`. Check off items in `todos.md` as they pass on real hardware.
