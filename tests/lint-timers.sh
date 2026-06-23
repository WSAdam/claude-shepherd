#!/usr/bin/env bash
# lint-timers.sh - guard against GC-unsafe timers in claude-dashboard.lua.
#
# hs.timer.doAfter/doEvery returns a timer that, if nothing holds a strong reference,
# can be garbage-collected BEFORE it fires -- silently skipping the scheduled work
# (the chronic nudge/clear/compact/reload flakiness this project fought repeatedly;
# see the after() wrapper + the Makefile `reload` comment). The safe forms all ASSIGN
# the timer to a retained handle (a module field `M.x`, a table field, a retained
# local, or the after() wrapper's own `local t = hs.timer.doAfter`). A bare
# `hs.timer.doAfter(...)` with no assignment target is the bug -> fail.

. "$(dirname "$0")/lib.sh"

DASH="$ROOT/claude-dashboard.lua"

# A timer line is SAFE iff the call is the RHS of an assignment
# (`... = hs.timer.(doAfter|doEvery)(`). Anything else is a bare, GC-unsafe call.
scan() { # $1 = file
  grep -nE 'hs\.timer\.(doAfter|doEvery)\(' "$1" \
    | grep -vE '=[[:space:]]*hs\.timer\.(doAfter|doEvery)\(' || true
}

assert_eq "no bare (unretained) hs.timer.doAfter/doEvery in claude-dashboard.lua" "" "$(scan "$DASH")"

# Positive control: a planted bare timer MUST be caught, so a broken regex can't make
# the absence check pass vacuously (a no-op tripwire is worse than none).
tmp="$(mktemp)"; cp "$DASH" "$tmp"
printf '%s\n' "  hs.timer.doAfter(1, function() doThing() end)" >> "$tmp"
assert_eq "guard fires on a planted bare timer (no vacuous pass)" \
  "1" "$(scan "$tmp" | grep -c 'doThing')"
rm -f "$tmp"

finish
