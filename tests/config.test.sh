#!/usr/bin/env bash
# config.test.sh - cc_config (cc-lib.sh) reads ~/.claude/cc-config.json with safe,
# off-by-default fallbacks. Runs against a temp config + temp status dir.

. "$(dirname "$0")/lib.sh"

TMP="$(mktemp_dir)"
trap 'rm -rf "$TMP"' EXIT
CFG="$TMP/cc-config.json"

# helper: evaluate cc_config in a subshell with the temp config + status dir
cfg() { CC_STATUS_DIR="$TMP" CC_CONFIG_FILE="$CFG" bash -c '. "'"$ROOT"'/cc-lib.sh"; cc_config "'"$1"'" "'"$2"'"'; }

# missing file -> default
assert_eq "missing file -> default" "false" "$(cfg '.queue.autofeed' 'false')"

printf '{"queue":{"autofeed":true,"dryRun":false},"policies":{"approveRepeats":false}}' > "$CFG"
assert_eq "present true" "true" "$(cfg '.queue.autofeed' 'false')"
assert_eq "false is preserved, not defaulted" "false" "$(cfg '.policies.approveRepeats' 'true')"
assert_eq "missing key -> default" "dflt" "$(cfg '.policies.nope.x' 'dflt')"
assert_eq "explicit false dryRun" "false" "$(cfg '.queue.dryRun' 'true')"

finish
