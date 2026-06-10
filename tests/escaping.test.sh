#!/usr/bin/env bash
# escaping.test.sh - XSS tripwire (R2-G). User-controlled group names and relabels flow
# into the panel webview via innerHTML; the ONLY defense is the JS esc() helper applied at
# each sink. This is a SOURCE-LEVEL tripwire, not a behavioral test -- the panel JS has no
# headless runtime in this Lua+bash suite. It fails if a known sink drops its esc() wrapper,
# or if esc() stops entity-encoding the HTML metacharacters. Reformatting a sink (e.g.
# `esc( it.group )`) can false-alarm; that's intentional -- re-verify the escape when you
# touch these lines. (A real behavioral test would need the headless-JS twin harness.)

. "$(dirname "$0")/lib.sh"

DASH="$ROOT/claude-dashboard.lua"
has() { grep -qF "$1" "$DASH" && echo yes || echo no; }

# 1. every user-controlled string reaches innerHTML through esc()
assert_eq "group filter chip label is esc()'d"  "yes" "$(has 'esc(g)')"
assert_eq "per-tile group tag is esc()'d"        "yes" "$(has 'esc(it.group)')"
assert_eq "tile display label/name is esc()'d"   "yes" "$(has 'esc(it.label')"

# 2. esc() itself still entity-encodes the HTML metacharacters (not gutted to a no-op)
assert_eq "esc() encodes &"  "yes" "$(has '.replace(/&/g,"&amp;")')"
assert_eq "esc() encodes <"  "yes" "$(has '.replace(/</g,"&lt;")')"
assert_eq "esc() encodes >"  "yes" "$(has '.replace(/>/g,"&gt;")')"
assert_eq 'esc() encodes "'  "yes" "$(has '.replace(/"/g,"&quot;")')"

finish
