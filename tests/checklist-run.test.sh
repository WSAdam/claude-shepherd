#!/usr/bin/env bash
# checklist-run.test.sh - ~/.claude/cc-run.sh, how a checklist run's session reports (2026-10-03,
# mining round 2 unit D3b). Run selected in My List opens one fresh session per item; an item that
# isn't a file line (Adam's own, an audit finding) is finished only when ITS session runs
# `cc-run.sh done <run> <item>`, and any item's session can say it's stuck with `cc-run.sh blocked
# <run> <item> --note "<why>"`. The script leaves ~/.claude/cc-run/<run>.<item>.<epoch>-<pid>.json
# (temp, then renamed) beside the run's own <run>.run.json, which only Shepherd writes; Shepherd
# takes the report on its next tick, only from that item's own session (core.runRecordReport).
# Drives the REAL cc-run.sh over a temp dir, and reads its records back with core.parseRunReport.
source "$(dirname "$0")/lib.sh"

TMP="$(mktemp_dir)"
trap 'rm -rf "$TMP"' EXIT
export CC_RUN_DIR="$TMP/cc-run"
mkdir -p "$CC_RUN_DIR" "$TMP/proj"
R="$ROOT/cc-run.sh"
RUN="r1a2b3c4d"
# the run Shepherd wrote: three items, the second Adam's own
cat > "$CC_RUN_DIR/$RUN.run.json" <<'JSON'
{"v":1,"id":"r1a2b3c4d","key":"shop","root":"/r/shop","startedBy":"adam","startedAt":1790000000,"phase":"running",
 "misses":0,"cur":2,"items":[
  {"n":1,"id":"t1","text":"fix the parser","kind":"file","file":"/r/shop/TODO.md","srcText":"fix the parser","state":"done"},
  {"n":2,"id":"o1","text":"renew the cert","kind":"report","state":"open","session":{"id":"S2"}},
  {"n":3,"id":"o2","text":"rotate the key","kind":"report","state":"queued"}]}
JSON

# crun <out> <session id> args... -> $TMP/<out>.out (stdout), .err (stderr), .rc
crun() {
  local o="$1" sid="$2"; shift 2
  (cd "$TMP/proj" && CLAUDE_CODE_SESSION_ID="$sid" bash "$R" "$@" > "$TMP/$o.out" 2> "$TMP/$o.err"; echo $? > "$TMP/$o.rc")
}
reports() { ls "$CC_RUN_DIR" | grep -E "^$RUN\.$1\.[0-9]+-[0-9]+\.json$"; }

# ---- the CLI's refusals ----
out="$(env -u CLAUDE_CODE_SESSION_ID bash "$R" --help 2>&1)"; rc=$?
assert_eq "--help works outside a session" "0" "$rc"
case "$out" in *"cc-run.sh done <run> <item>"*"cc-run.sh blocked <run> <item>"*) r=yes ;; *) r="no: $out" ;; esac
assert_eq "...and shows done and blocked" "yes" "$r"
out="$(cd "$TMP/proj" && env -u CLAUDE_CODE_SESSION_ID bash "$R" done "$RUN" 2 2>&1)"; rc=$?
assert_eq "outside a Claude Code session: refused (exit 2)" "2" "$rc"
case "$out" in *CLAUDE_CODE_SESSION_ID*) r=yes ;; *) r="no: $out" ;; esac
assert_eq "...saying why" "yes" "$r"
crun badcmd S2 finish "$RUN" 2
assert_eq "an unknown verdict: refused" "2" "$(cat "$TMP/badcmd.rc")"
crun badrun S2 done "../etc" 2
assert_eq "a run id that isn't one: refused" "2" "$(cat "$TMP/badrun.rc")"
crun baditem S2 done "$RUN" two
assert_eq "an item that isn't a number: refused" "2" "$(cat "$TMP/baditem.rc")"
crun norun S2 done r9999999 2
assert_eq "a run Shepherd never started: refused" "2" "$(cat "$TMP/norun.rc")"
case "$(cat "$TMP/norun.err")" in *"no checklist run"*) r=yes ;; *) r="no: $(cat "$TMP/norun.err")" ;; esac
assert_eq "...saying there's no such run" "yes" "$r"
crun noitem S2 done "$RUN" 7
assert_eq "an item the run doesn't have: refused" "2" "$(cat "$TMP/noitem.rc")"
crun nonote S2 blocked "$RUN" 2
assert_eq "blocked without a reason: refused" "2" "$(cat "$TMP/nonote.rc")"
long="$(printf 'x%.0s' $(seq 1 301))"
crun longnote S2 done "$RUN" 2 --note "$long"
assert_eq "a note over 300 characters: refused" "2" "$(cat "$TMP/longnote.rc")"
assert_eq "...and nothing was reported" "" "$(ls "$CC_RUN_DIR" | grep -v '\.run\.json$')"

# ---- done ----
crun done1 S2 done "$RUN" 2
assert_eq "done: exits 0" "0" "$(cat "$TMP/done1.rc")"
case "$(cat "$TMP/done1.out")" in *"item 2"*) r=yes ;; *) r="no: $(cat "$TMP/done1.out")" ;; esac
assert_eq "...and says what it reported" "yes" "$r"
F="$(reports 2 | head -1)"
assert_eq "done: the report is <run>.<item>.<epoch>-<pid>.json" "yes" "$([ -n "$F" ] && echo yes || echo no)"
FP="$CC_RUN_DIR/$F"
assert_json "...v1" "$FP" '.v' "1"
assert_json "...its id is its name's tail" "$FP" '.id' "$(printf '%s' "$F" | sed -E "s/^$RUN\.2\.//; s/\.json$//")"
assert_json "...the run" "$FP" '.run' "$RUN"
assert_json "...the item, as a number" "$FP" '.item' "2"
assert_json "...the verdict" "$FP" '.verdict' "done"
assert_json "...no note" "$FP" '.note' "null"
assert_json "...the session that sent it" "$FP" '.session_id' "S2"
assert_json "...where it ran" "$FP" '.cwd' "$(cd "$TMP/proj" && pwd)"
assert_json "...when" "$FP" '(.at | type)' "number"
assert_eq "...written whole (no temp left)" "" "$(ls "$CC_RUN_DIR" | grep -vE '\.json$')"

crun done2 S2 done "$RUN" 2 --note "renewed it,
  and   checked the expiry"
F2="$(reports 2 | grep -v "^$F$" | head -1)"
assert_json "done --note: the note, on one line" "$CC_RUN_DIR/$F2" '.note' "renewed it, and checked the expiry"

# ---- blocked ----
crun blk S2 blocked "$RUN" 2 --note "needs the API key"
assert_eq "blocked --note: exits 0" "0" "$(cat "$TMP/blk.rc")"
FB="$(ls -t "$CC_RUN_DIR" | grep -E "^$RUN\.2\." | head -1)"
assert_json "...the verdict" "$CC_RUN_DIR/$FB" '.verdict' "blocked"
assert_json "...and why" "$CC_RUN_DIR/$FB" '.note' "needs the API key"
rm -f "$CC_RUN_DIR/$RUN".2.*
crun blkpos S2 blocked "$RUN" 2 "the vault is locked"
assert_eq "blocked <note> (the note as the last word): exits 0" "0" "$(cat "$TMP/blkpos.rc")"
assert_json "...the note" "$CC_RUN_DIR/$(reports 2 | head -1)" '.note' "the vault is locked"

# ---- Shepherd reads exactly what the script writes (KEEP THE FIELDS IN SYNC) ----
rm -f "$CC_RUN_DIR/$RUN".2.*
crun sync S2 done "$RUN" 2 --note "all good"
FS="$(reports 2 | head -1)"
got="$(lua - "$ROOT" "$FS" "$CC_RUN_DIR/$FS" <<'LUA' 2>&1
local root, name, path = arg[1], arg[2], arg[3]
local core = dofile(root .. "/cc-core.lua")
core.json = dofile(root .. "/tests/support/json.lua")
local f = io.open(path, "r"); local raw = f:read("*a"); f:close()
local r = core.parseRunReport(name, raw)
print(r and (r.run .. "|" .. r.n .. "|" .. r.verdict .. "|" .. tostring(r.note) .. "|" .. r.session_id) or "nil")
LUA
)"
assert_eq "core.parseRunReport reads the script's record" "$RUN|2|done|all good|S2" "$got"

finish
