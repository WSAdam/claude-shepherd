#!/usr/bin/env bash
# worklist-ui.test.sh - source-level wiring tripwire for the My-List panel UI added
# on top of the pure cc-core worklist ops (those are behaviorally tested in
# core.test.lua). Like escaping.test.sh, the panel JS has no headless runtime in this
# Lua+bash suite, so this asserts the WIRING is present end-to-end: the front-end sink
# (textarea + Shift+Enter, per-item ✕ delete) AND the Lua bridge that services it
# (`worklist-remove` -> core.worklistRemove). It fails if a refactor silently drops a
# leg of either feature. Re-verify behavior by eye when you intentionally touch these.

. "$(dirname "$0")/lib.sh"

DASH="$ROOT/claude-dashboard.lua"
has() { grep -qF "$1" "$DASH" && echo yes || echo no; }

# ---- Feature 1: multi-line add input (Enter adds, Shift+Enter newline, auto-grow) --
# The add field must be a <textarea> (an <input type=text> cannot hold a newline).
assert_eq "add field is a <textarea> (multi-line capable)" "yes" "$(has '<textarea id="wl-input"')"
assert_eq "add input has NO single-line <input> remnant"   "no"  "$(has '<input id="wl-input"')"
# Enter adds, Shift+Enter falls through to a newline.
assert_eq "Enter-vs-Shift+Enter handler is wired"  "yes" "$(has 'onkeydown="onWorklistKey(event)"')"
assert_eq "Shift+Enter is the newline escape hatch" "yes" "$(has '!e.shiftKey')"
assert_eq "add input grows with content (oninput autoGrow)" "yes" "$(has 'oninput="autoGrow(this)"')"
# After adding, the grown textarea height is reset (so the next item starts compact).
assert_eq "add resets the textarea height" "yes" "$(has 'inp.style.height = "auto"')"

# ---- Feature 2: per-item delete -----------------------------------------------------
# Each rendered row carries a ✕ button tagged with its item id...
assert_eq "row renders a ✕ delete button"        "yes" "$(has 'class="wl-del" data-del="')"
# ...read by a DELEGATED click handler (rows are re-rendered, so no inline onclick)...
assert_eq "delegated delete handler reads data-del" "yes" "$(has 'worklistRemove(did)')"
# ...which posts the worklist-remove bridge message for the current scope...
assert_eq "JS worklistRemove posts worklist-remove" "yes" "$(has 'send("worklist-remove", worklistScope, id)')"
# ...and the Lua side dispatches it to the pure core remover.
assert_eq "Lua bridge handles worklist-remove"   "yes" "$(has 'a == "worklist-remove"')"
# Pin the full arg mapping: id arrives via payload.text (NOT payload.v, which is the scope).
assert_eq "Lua bridge removes by payload.text id" "yes" "$(has 'core.worklistRemove(st, scope, tostring(payload.text')"

# ---- XSS: the per-item id reaches two attributes; both go through esc() --------------
# (item text is covered by escaping.test.sh; the id is server-minted but still escaped.)
assert_eq "item id is esc()'d before the attribute" "yes" "$(has 'esc(String(it.id || ""))')"

# Positive control: prove `has` actually distinguishes present/absent, so a typo in a
# needle above can't make an assert pass vacuously.
assert_eq "control: a string that cannot exist is absent" "no" "$(has 'wl-this-token-does-not-exist-xyzzy')"

finish
