#!/usr/bin/env bash
# lib.sh - tiny assert helpers for babysitter's bash tests. Side-effect-free:
# every suite runs against its own temp CC_STATUS_DIR and cleans up on exit.

TESTS_RUN=0
TESTS_FAIL=0

# project root (tests/ is one level down)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

mktemp_dir() { mktemp -d 2>/dev/null || mktemp -d -t ccbabysit; }

assert_eq() { # <name> <expected> <actual>
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ "$2" = "$3" ]; then
    echo "ok   - $1"
  else
    TESTS_FAIL=$((TESTS_FAIL + 1))
    echo "FAIL - $1 (expected [$2] got [$3])"
  fi
}

# assert a jq query against a JSON file
assert_json() { # <name> <file> <jq-filter> <expected>
  local got
  got="$(jq -r "$3" "$2" 2>/dev/null)"
  assert_eq "$1" "$4" "$got"
}

# assert a file does NOT exist
assert_absent() { # <name> <path>
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ ! -e "$2" ]; then
    echo "ok   - $1"
  else
    TESTS_FAIL=$((TESTS_FAIL + 1))
    echo "FAIL - $1 (expected [$2] to be absent)"
  fi
}

finish() {
  echo "-- $(basename "$0"): $TESTS_RUN run, $TESTS_FAIL failed --"
  [ "$TESTS_FAIL" -eq 0 ]
  exit $?
}
