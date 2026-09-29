#!/usr/bin/env bash
# lib.sh - tiny assert helpers for Claude Shepherd's bash tests. Side-effect-free:
# every suite runs against its own temp CC_STATUS_DIR and cleans up on exit.

TESTS_RUN=0
TESTS_FAIL=0

# project root (tests/ is one level down)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

mktemp_dir() { mktemp -d 2>/dev/null || mktemp -d -t ccshepherd; }

# 2026-09-28: a hook driven by a suite that set only CC_STATUS_DIR read the REAL
# ~/.claude/cc-config.json (Adam's has the ledger on) and appended the suite's fake events to
# the real ~/.claude/cc-ledger -- ~15k over a month. Every suite now gets its own ledger dir and
# an empty config unless it sets its own after sourcing this file (tests/ledger-isolation.test.sh).
CC_TEST_ISOLATION="$(mktemp_dir)"
export CC_LEDGER_DIR="${CC_LEDGER_DIR:-$CC_TEST_ISOLATION/ledger}"
export CC_CONFIG_FILE="${CC_CONFIG_FILE:-$CC_TEST_ISOLATION/cc-config.json}"
# 2026-09-28: SessionStart reads (and consumes) the handoff notes a respawn leaves in
# ~/.claude/cc-notes/pending; a suite's fake session must never take a real one.
export CC_NOTES_DIR="${CC_NOTES_DIR:-$CC_TEST_ISOLATION/cc-notes}"
# 2026-09-29: a Stop or SessionStart hands over (and removes) the messages Shepherd left in
# ~/.claude/cc-inbox; a suite's fake session must never take a real one.
export CC_INBOX_DIR="${CC_INBOX_DIR:-$CC_TEST_ISOLATION/cc-inbox}"
# 2026-09-29: a clean Stop or a SessionEnd clears the resume Shepherd armed in ~/.claude/cc-resume
# (cc-resume.sh); a suite's fake session must never clear a real one.
export CC_RESUME_DIR="${CC_RESUME_DIR:-$CC_TEST_ISOLATION/cc-resume}"

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

# wait until a path exists: 0 once it does, 1 after <tries> 0.1s polls (default 60 = 6s)
wait_for() { # <path> [tries]
  local i; for i in $(seq 1 "${2:-60}"); do [ -e "$1" ] && return 0; sleep 0.1; done; return 1
}

# newhook_repo <dir> - a copy of this checkout's installer that ships ONE hook more than the real
# one: cc-newhook.sh, listed in SHIPPED, added to the Stop group Shepherd already owns and wired in
# a new StopFailure group of its own (matcher rate_limit). It stands in for the next release that
# adds a hook, so the upgrade path is tested before one exists. Echoes <dir>.
newhook_repo() {
  local d="$1"
  mkdir -p "$d"
  cp "$ROOT"/install.sh "$ROOT"/uninstall.sh "$ROOT"/Makefile "$ROOT"/cc-*.sh "$ROOT"/cc-core.lua \
     "$ROOT"/cc-scrub.js "$ROOT"/claude-dashboard.lua "$d/"
  [ -r "$ROOT/SHIPPED" ] && cp "$ROOT/SHIPPED" "$d/"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/cc-newhook.sh"
  printf 'cc-newhook.sh         claude hook\n' >> "$d/SHIPPED"
  jq '.hooks.Stop[0].hooks += [{type: "command", command: "bash \"$HOME/.claude/cc-newhook.sh\" stop"}]
      | .hooks.StopFailure += [{matcher: "rate_limit", hooks: [
          {type: "command", command: "bash \"$HOME/.claude/cc-newhook.sh\" ratelimit"}]}]' \
    "$ROOT/settings-hooks.json" > "$d/settings-hooks.json"
  printf '%s' "$d"
}

finish() {
  echo "-- $(basename "$0"): $TESTS_RUN run, $TESTS_FAIL failed --"
  [ -n "${CC_TEST_ISOLATION:-}" ] && rm -rf "$CC_TEST_ISOLATION"
  [ "$TESTS_FAIL" -eq 0 ]
  exit $?
}
