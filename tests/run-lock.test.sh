#!/usr/bin/env bash
# run-lock.test.sh - tests/run.sh refuses a second concurrent run in the same checkout.
#
# 2026-09-17: Shepherd's merge test gate started TWO runs of `make lint && make test` in the
# same main checkout at the same moment. The suite is genuinely not concurrency-safe there --
# install.test.sh shells out to the real `make` in the checkout (its reload test stops only its
# own fake `hs`, never the real one) -- so the two runs killed each other and both reported `exited 2`, while main was
# green. Shepherd now serialises its own gates, and the suite refuses the overlap itself, which
# also protects Adam's own hand-run. Exit code and token are core.TEST_LOCK_EXIT / _TOKEN.
#
# Side-effect-free: never runs the suite. Every check drives the lock preamble with the lock
# already held, or exercises the preamble in a throwaway copy of run.sh.
source "$(dirname "$0")/lib.sh"

TMP="$(mktemp_dir)"
trap 'rm -rf "$TMP"' EXIT

LOCK_EXIT="$(lua -e 'local c = dofile("'"$ROOT"'/cc-core.lua") io.write(tostring(c.TEST_LOCK_EXIT))')"
LOCK_TOKEN="$(lua -e 'local c = dofile("'"$ROOT"'/cc-core.lua") io.write(tostring(c.TEST_LOCK_TOKEN))')"
assert_eq "cc-core names the suite's refusal exit code" "9" "$LOCK_EXIT"
assert_eq "cc-core names the suite's refusal token" "CC_TEST_SUITE_LOCKED" "$LOCK_TOKEN"

# The preamble is the top of run.sh, cut just before the first suite it would run. Copied into
# a temp tests/ dir so a check can never start the real suite.
STUB="$TMP/tests"
mkdir -p "$STUB"
awk '/^echo "== / { exit } { print }' "$ROOT/tests/run.sh" > "$STUB/run.sh"
cp "$ROOT/tests/hermetic-env.sh" "$STUB/hermetic-env.sh"
printf 'echo REACHED-THE-SUITES\n' >> "$STUB/run.sh"

assert_eq "the preamble alone reaches the suites when nothing holds the lock" "REACHED-THE-SUITES" \
  "$(bash "$STUB/run.sh" 2>&1 | tail -n 1)"

# ---- a live holder is refused ----
# $$ of this test process is alive, so it stands in for a run that is still going.
mkdir -p "$STUB/.run.lock"
printf '%s\n' "$$" > "$STUB/.run.lock/pid"
out="$(bash "$STUB/run.sh" 2>&1)"; code=$?
assert_eq "a second run in the same checkout exits with the suite's own code" "$LOCK_EXIT" "$code"
assert_eq "...prints the machine token, so a wrapper like make can't hide it" "1" \
  "$(printf '%s' "$out" | grep -Fc "$LOCK_TOKEN")"
assert_eq "...says another run of this suite holds it" "1" \
  "$(printf '%s' "$out" | grep -ci 'already running')"
assert_eq "...names the pid holding it" "1" "$(printf '%s' "$out" | grep -Fc "$$")"
assert_eq "...and never reaches a suite" "0" \
  "$(printf '%s' "$out" | grep -Fc 'REACHED-THE-SUITES')"
assert_eq "...and leaves the holder's lock alone" "1" \
  "$([ -d "$STUB/.run.lock" ] && echo 1 || echo 0)"

# ---- a lock left behind by a dead process is taken over, not a permanent wedge ----
# A pid that cannot be running: fork a true(1) and wait for it to exit.
( exec true ) & DEADPID=$!; wait "$DEADPID" 2>/dev/null
printf '%s\n' "$DEADPID" > "$STUB/.run.lock/pid"
out="$(bash "$STUB/run.sh" 2>&1)"; code=$?
assert_eq "a lock whose holder is gone doesn't wedge the suite forever" "0" "$code"
assert_eq "...it takes the lock over and runs" "1" \
  "$(printf '%s' "$out" | grep -Fc 'REACHED-THE-SUITES')"

# ---- the lock is released when the run finishes ----
assert_eq "a finished run leaves no lock behind" "0" \
  "$([ -e "$STUB/.run.lock" ] && echo 1 || echo 0)"

# ---- the lock is per checkout: a worktree's own run is never blocked by main's ----
OTHER="$TMP/other/tests"
mkdir -p "$OTHER"
cp "$STUB/run.sh" "$OTHER/run.sh"; cp "$STUB/hermetic-env.sh" "$OTHER/hermetic-env.sh"
mkdir -p "$STUB/.run.lock"; printf '%s\n' "$$" > "$STUB/.run.lock/pid"
assert_eq "another checkout's suite runs in parallel, as the worktree workflow needs" "REACHED-THE-SUITES" \
  "$(bash "$OTHER/run.sh" 2>&1 | tail -n 1)"
rm -rf "$STUB/.run.lock"

# The lock lives inside the checkout, so it must be gitignored -- an untracked file in a
# worktree makes `git worktree remove` refuse (tests/worktree-hygiene.test.sh's lesson).
if git -C "$ROOT" check-ignore -q tests/.run.lock; then got=ignored; else got=untracked; fi
assert_eq "the suite's lock is gitignored" "ignored" "$got"

finish
