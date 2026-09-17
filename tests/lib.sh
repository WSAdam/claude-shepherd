#!/usr/bin/env bash
# lib.sh - tiny assert helpers for Claude Shepherd's bash tests. Side-effect-free:
# every suite runs against its own temp CC_STATUS_DIR and cleans up on exit.

TESTS_RUN=0
TESTS_FAIL=0

# project root (tests/ is one level down)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

mktemp_dir() { mktemp -d 2>/dev/null || mktemp -d -t ccshepherd; }

# sysbin_without <outdir> <tool>... - mirror /usr/bin + /bin into <outdir> as symlinks,
# leaving out the named tools, and echo <outdir>. Use it in place of a literal
# "/usr/bin:/bin" wherever a test proves install.sh REPORTS or ABORTS on a missing tool.
#
# 2026-09-17: those tests faked "absent" with PATH="$STUBS:/usr/bin:/bin" on the stated
# assumption that lua/node are never system tools -- true on macOS, where they come from
# Homebrew, and FALSE on Linux, where apt puts lua, luac and node straight in /usr/bin.
# Running the suite on Linux (the new CI job) found both of them silently passing the
# probe, so the assertions proved nothing there. Scrubbing by name is platform-neutral:
# the tool is genuinely unreachable, and every other system utility still is.
sysbin_without() { # <outdir> <tool>...
  local out="$1"; shift
  mkdir -p "$out"
  local d f b t skip
  for d in /usr/bin /bin; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
      [ -x "$f" ] || continue
      b="${f##*/}"
      skip=0
      for t in "$@"; do [ "$b" = "$t" ] && skip=1 && break; done
      [ "$skip" = 1 ] && continue
      [ -e "$out/$b" ] || ln -s "$f" "$out/$b" 2>/dev/null || true
    done
  done
  printf '%s' "$out"
}

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
