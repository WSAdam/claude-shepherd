#!/usr/bin/env bash
# worklist-ui.test.sh - source-level wiring tripwire for the My-List panel UI added
# on top of the pure cc-core worklist ops (those are behaviorally tested in
# core.test.lua). Like escaping.test.sh, the panel JS has no headless runtime in this
# Lua+bash suite, so this asserts the WIRING is present end-to-end: the front-end sink
# (the add/open item MODAL — subject + details + expected date — and the per-item ✕
# delete) AND the Lua bridge that services it (`worklist-remove` -> core.worklistRemove).
# It fails if a refactor silently drops a leg of either feature. Re-verify behavior by
# eye when you intentionally touch these.

. "$(dirname "$0")/lib.sh"

DASH="$ROOT/claude-dashboard.lua"
has() { grep -qF "$1" "$DASH" && echo yes || echo no; }

# ---- Feature 1: the item modal is the ONE place an item is written -----------------
# Adding opens the modal (there is no inline add field any more).
assert_eq "add row is a modal-opening button" "yes" "$(has 'id="wl-addbtn" onclick="wlModalOpen('"'"''"'"')"')"
assert_eq "no inline add textarea remnant"    "no"  "$(has '<textarea id="wl-input"')"
# The modal collects all three fields...
assert_eq "modal has a subject field"       "yes" "$(has 'id="wl-msubj"')"
assert_eq "modal has a details field"       "yes" "$(has '<textarea id="wl-mdet"')"
assert_eq "modal has a date field"          "yes" "$(has 'id="wl-mdue" type="date"')"
# ...and Save posts them: a new item via worklist-add, an existing one via worklist-edit.
assert_eq "add posts subject+details+due"   "yes" "$(has 'a:"worklist-add", v:worklistScope, text:subj, details:details, due:due')"
assert_eq "edit posts id+subject+details+due" "yes" "$(has 'a:"worklist-edit", v:worklistScope, text:id, edit:subj, details:details, due:due')"
# The Lua bridge forwards both extras to the pure core ops.
assert_eq "Lua bridge reads payload.details/due" "yes" "$(has 'local extra = { details = tostring(payload.details or ""), due = tostring(payload.due or ""),')"
# The checklist rides along; omitted -> nil, so core leaves an existing list alone.
assert_eq "Lua bridge passes payload.steps through" "yes" "$(has 'steps = (type(payload.steps) == "table") and payload.steps or nil }')"
assert_eq "modal has a checklist area"      "yes" "$(has 'id="wl-msteps"')"
assert_eq "date arrows nudge a day"         "yes" "$(has 'onclick="wlDueShift(-1)"')"
assert_eq "date has a reset-to-today control" "yes" "$(has 'onclick="wlDueReset()"')"
assert_eq "date can be cleared for a no-date item" "yes" "$(has 'onclick="wlDueClear()"')"
assert_eq "Lua add passes the extras"       "yes" "$(has 'FX.worklistNewId(), FX.now(), extra)')"
assert_eq "Lua edit passes the extras"      "yes" "$(has 'tostring(payload.edit or ""), extra)')"
# A row shows subject + date and opens the modal when clicked.
assert_eq "row carries its open id"         "yes" "$(has 'class="wl-item" data-open="')"
assert_eq "row click opens the modal"       "yes" "$(has 'if(rid) wlModalOpen(rid)')"
assert_eq "row renders the due-date chip"   "yes" "$(has 'wlDueChip(it.due, isDone)')"
# ⌘V paste into a modal field goes through the Lua clipboard bridge (WKWebView won't
# deliver the paste event to a JS handler reliably), and the nudge box is read-only meanwhile.
# THE paste bug: the panel's single ⌘V eventtap swallows the keystroke panel-wide and
# used to force-feed EVERY paste to the nudge box, so no in-page handler could ever run.
# It must route to the modal's focused field while the modal is open.
assert_eq "the ⌘V tap checks the modal flag first" "yes" "$(has 'if txt and #txt > 0 and FX.wlModalOpen then')"
assert_eq "the tap routes the clipboard to the modal" "yes" "$(has 'wv:evaluateJavaScript("window.wlReceiveClipboard(" .. jsString(txt) .. ")")')"
assert_eq "modal open/close sets the Lua flag"  "yes" "$(has 'FX.wlModalOpen = (tostring(payload.v or "") == "open")')"
assert_eq "JS announces the modal open"         "yes" "$(has 'send("worklist-modal", "open")')"
assert_eq "JS announces the modal close"        "yes" "$(has 'send("worklist-modal", "close")')"
assert_eq "clipboard text lands in a modal field" "yes" "$(has 'window.wlReceiveClipboard = function(txt)')"
assert_eq "nudge is read-only while the modal is open" "yes" "$(has 'if(nud) nud.readOnly = true;')"

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

# ---- Feature 3: the MASTER rollup tab (read-only, date-priority) ---------------------
assert_eq "MASTER chip renders first"       "yes" "$(has 'data-scope="master"')"
assert_eq "master rolls every scope up"     "yes" "$(has 'function wlMasterRows(')"
assert_eq "undated items sort last"         "yes" "$(has '"9999-99-99"')"
assert_eq "master hides the add row"        "yes" "$(has 'document.getElementById("wl-addrow").style.display = isMaster ? "none" : "flex"')"
assert_eq "master row carries its home scope" "yes" "$(has 'data-mscope="')"
assert_eq "clicking a master row jumps to that tab" "yes" "$(has 'worklistScope = ms; renderWorklist();')"
# Ticking a master row writes to the item's OWN scope, never the visible tab.
assert_eq "master row has its own checkbox"   "yes" "$(has 'class="wl-cb wl-mcb"')"
assert_eq "master tick toggles in its home scope" "yes" "$(has 'if(ms && mid) send("worklist-toggle", ms, mid);')"
# MASTER "Recently completed" drawer: last-7-days window, sorted newest-first.
assert_eq "master has a recently-completed drawer" "yes" "$(has 'id="wl-mdonewrap"')"
assert_eq "recently-completed windows 7 days"  "yes" "$(has '7 * 86400')"
assert_eq "toggle stamps a completion time"    "yes" "$(has 'core.worklistToggle(st, scope, tostring(payload.text or ""), FX.now())')"
# Per-scope Done is ordered by due date.
assert_eq "done rows sorted by due date"       "yes" "$(has 'done.sort(function(a, b){ return wlDueSort(b.due)')"
# EVERY scope's done row carries both dates (expected + ✓ completed), not just MASTER.
assert_eq "done rows show due AND completed"   "yes" "$(has 'wlDueChip(it.due, isDone)
                + (isDone ? wlDoneChip(it.doneTs) : "")')"
assert_eq "the ✓ stamp is a shared helper"     "yes" "$(has 'function wlDoneChip(dts)')"
assert_eq "master reuses the same ✓ helper"    "yes" "$(has 'wlDueChip(r.it.due, true) + wlDoneChip(r.dts)')"
# An item finished before completion times existed has no stamp (never "✓ NaN").
assert_eq "no timestamp renders no stamp"      "yes" "$(has 'return s ? ')"
# Offline projects (a saved list but no live session) still get a tab + MASTER rows.
assert_eq "payload adds offline projects from byProject" "yes" "$(has 'for k, list in pairs(st.byProject or {}) do')"
assert_eq "offline projects are labeled from persisted stores" "yes" "$(has 'or autos[k] or core.projectKeyLabel(k)')"

# ---- XSS: the per-item id reaches two attributes; both go through esc() --------------
# (item text is covered by escaping.test.sh; the id is server-minted but still escaped.)
assert_eq "item id is esc()'d before the attribute" "yes" "$(has 'esc(String(it.id || ""))')"

# Positive control: prove `has` actually distinguishes present/absent, so a typo in a
# needle above can't make an assert pass vacuously.
assert_eq "control: a string that cannot exist is absent" "no" "$(has 'wl-this-token-does-not-exist-xyzzy')"

finish
