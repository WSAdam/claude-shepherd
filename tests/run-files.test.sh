#!/usr/bin/env bash
# run-files.test.sh - tests/run.sh with file arguments runs just those files (2026-09-29).
#
# Shepherd's red-first proof (build program unit 20) runs a unit's changed test files on the
# merge-base, without the unit's fix: merge.gates' redFirstCommand "bash tests/run.sh {files}".
# That needs the suite to take file arguments -- each file by its own interpreter, under a
# `== <path> ==` header the proof ties FAIL lines to -- and a file that dies before it names a
# failing test (a crash at load: the function the fix adds isn't there yet) still says FAIL.
#
# Side-effect-free: runs a copy of run.sh in a temp dir against throwaway test files.
source "$(dirname "$0")/lib.sh"

TMP="$(mktemp_dir)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/tests"
cp "$ROOT/tests/run.sh" "$ROOT/tests/hermetic-env.sh" "$TMP/tests/"
printf 'echo "ok   - fine"\n' > "$TMP/tests/pass.test.sh"
printf 'echo "ok   - fine"\necho "FAIL - the new thing"\nexit 1\n' > "$TMP/tests/fail.test.sh"
printf 'print("HOME=" .. tostring(os.getenv("HOME")))\nlocal core = {}\ncore.redFirstNew()\n' > "$TMP/tests/crash.test.lua"
printf 'console.log("FAIL - js new"); process.exit(1);\n' > "$TMP/tests/js.test.js"
printf 'echo "SHOULD-NOT-RUN"\n' > "$TMP/tests/other.test.sh"
printf 'x\n' > "$TMP/tests/odd.test.rb"

out="$(cd "$TMP" && bash tests/run.sh tests/pass.test.sh tests/fail.test.sh tests/crash.test.lua tests/js.test.js \
  tests/odd.test.rb tests/missing.test.sh 2>&1)"; code=$?
assert_eq "file mode exits non-zero when a named file fails" "1" "$code"
assert_eq "...runs only the files it was given, never the suite list" "0" \
  "$(printf '%s\n' "$out" | grep -c 'SHOULD-NOT-RUN\|== bash: config ==')"
assert_eq "...each under its own == <path> == header, in order" \
  "== tests/pass.test.sh ==|== tests/fail.test.sh ==|== tests/crash.test.lua ==|== tests/js.test.js ==|== tests/odd.test.rb ==|== tests/missing.test.sh ==" \
  "$(printf '%s\n' "$out" | grep '^== ' | paste -sd'|' -)"
assert_eq "...a file's own FAIL line comes through" "1" "$(printf '%s\n' "$out" | grep -c '^FAIL - the new thing$')"
assert_eq "...node runs a .js file" "1" "$(printf '%s\n' "$out" | grep -c '^FAIL - js new$')"
assert_eq "...a file that named its failure gets no extra line" "0" \
  "$(printf '%s\n' "$out" | grep -c '^FAIL - tests/js.test.js exited')"
crash="$(printf '%s\n' "$out" | grep '^FAIL - tests/crash.test.lua exited 1 before naming a failing test: ')"
assert_eq "...a crash before any FAIL line still says FAIL, naming the file" "1" "$(printf '%s\n' "$crash" | grep -c .)"
assert_eq "...quoting lua's own error line" "1" "$(printf '%s\n' "$crash" | grep -c "attempt to call")"
assert_eq "...lua suites run with a temp HOME, never the real one" "0" \
  "$(printf '%s\n' "$out" | grep -c "^HOME=$HOME\$")"
assert_eq "...a file with no known runner says so" "1" "$(printf '%s\n' "$out" | grep -c '^skipped: no runner for tests/odd.test.rb$')"
assert_eq "...a missing file says so" "1" "$(printf '%s\n' "$out" | grep -c '^not found: tests/missing.test.sh$')"
assert_eq "...and the run ends with the usual verdict" "❌ SOME TESTS FAILED" "$(printf '%s\n' "$out" | tail -n 1)"

out="$(cd "$TMP" && bash tests/run.sh tests/pass.test.sh 2>&1)"; code=$?
assert_eq "a named file that passes: exit 0" "0" "$code"
assert_eq "...ALL GREEN" "✅ ALL GREEN" "$(printf '%s\n' "$out" | tail -n 1)"

# file mode still takes the per-checkout lock: $$ stands in for a run that is still going
mkdir -p "$TMP/tests/.run.lock"
printf '%s\n' "$$" > "$TMP/tests/.run.lock/pid"
out="$(cd "$TMP" && bash tests/run.sh tests/pass.test.sh 2>&1)"; code=$?
assert_eq "file mode is refused while another run holds this checkout's lock" "9" "$code"
assert_eq "...with the machine token" "1" "$(printf '%s\n' "$out" | grep -c '^CC_TEST_SUITE_LOCKED$')"
rm -r "$TMP/tests/.run.lock"

finish
