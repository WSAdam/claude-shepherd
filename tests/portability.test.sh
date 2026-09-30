#!/usr/bin/env bash
# portability.test.sh - the suite has to run on Linux (CI, ubuntu) as well as on a Mac.
# Side-effect-free: reads the checkout.
#
# 2026-09-30: CI had been red since the build program was pushed, and nobody saw it locally,
# because both causes only bite off a Mac:
#   - tests/coach.test.lua stood in for hs.fs with BSD `stat -f`. On GNU that means "file-system
#     status" with another format, so every file read as missing, the coach found no transcripts,
#     never ran, and the test crashed.
#   - tests/reap-session-files.test.lua fed cc-lib.sh to os.execute, i.e. to plain `sh`. cc-lib.sh
#     is a bash library (every script that sources it starts `#!/usr/bin/env bash`); on a Mac `sh`
#     is bash, on ubuntu it is dash, which stopped at the first `[[ … =~ ^(…) ]]` it couldn't parse.
source "$(dirname "$0")/lib.sh"

# ---- BSD-only stat ------------------------------------------------------------
# `stat -f <format>` is BSD. A test that needs a file's type or time asks GNU first and falls
# back: `stat -c '%F|%Y' f 2>/dev/null || stat -f '%HT|%m' f` (GNU first: on GNU `stat -f`
# SUCCEEDS with the wrong answer). Comment lines may talk about it.
bsd_only="$(grep -n 'stat -f' "$ROOT"/tests/*.lua "$ROOT"/tests/*.js "$ROOT"/tests/*.sh "$ROOT"/tests/support/* 2>/dev/null \
  | grep -v 'stat -c' | grep -v '/portability\.test\.sh:' \
  | awk -F: '{ line = $0; sub(/^[^:]*:[0-9]+:/, "", line); if (line !~ /^[[:space:]]*(#|--|\/\/)/) print $1 ":" $2 }' \
  | sed "s|^$ROOT/||" | tr '\n' ' ')"
assert_eq "no test calls BSD stat -f without a GNU stat -c fallback on the same line" "" "$bsd_only"

# ---- the shell a shipped script is run with ------------------------------------------------
not_bash=""
for f in "$ROOT"/cc-*.sh; do
  [ "$(head -1 "$f")" = "#!/usr/bin/env bash" ] || not_bash="$not_bash ${f##*/}"
done
assert_eq "every shipped cc-*.sh is a bash script" "" "$not_bash"
# ...so a Lua test that sources one runs it with bash, never through os.execute's plain sh.
reap="$ROOT/tests/reap-session-files.test.lua"
if grep -q 'os.execute(("bash %q >/dev/null 2>&1"):format(REAP_SH))' "$reap"; then got=bash; else got="plain sh"; fi
assert_eq "the cc_remove reap test runs cc-lib.sh under bash" "bash" "$got"
if bash -n "$ROOT/cc-lib.sh" 2>/dev/null; then got=parses; else got="syntax error"; fi
assert_eq "cc-lib.sh parses as bash" "parses" "$got"

finish
