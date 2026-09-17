#!/usr/bin/env bash
# hermetic-env.test.sh - the suite ignores CC_* variables already set in the shell that runs it
# (2026-09-17). The dashboard and hooks honor overrides like CC_BRIDGE_DIR and CC_STATUS_DIR; the
# install gate runs the suite in the user's own shell, and a verification run with CC_BRIDGE_DIR
# exported failed 21 bridge checks. tests/run.sh sources tests/hermetic-env.sh first to drop them.
. "$(dirname "$0")/lib.sh"

got="$(CC_BRIDGE_DIR=/elsewhere CC_STATUS_DIR=/elsewhere CC_CODE_CLI=/bin/true NOT_OURS=kept \
  bash -c ". '$ROOT/tests/hermetic-env.sh'; echo \"\${CC_BRIDGE_DIR-unset} \${CC_STATUS_DIR-unset} \${CC_CODE_CLI-unset} \${NOT_OURS-unset}\"")"
assert_eq "an outside CC_* variable is dropped before the suite runs" "unset unset unset kept" "$got"
assert_eq "tests/run.sh sources hermetic-env.sh before any suite" "yes" \
  "$(awk '/hermetic-env\.sh/ { print (n == 0) ? "yes" : "no"; exit } /bash "\$DIR|lua "\$DIR|node "\$DIR/ { n++ }' "$ROOT/tests/run.sh")"

finish
