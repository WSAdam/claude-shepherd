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

# Providers + default-provider (read by the panel; no secrets stored in the file).
printf '%s' '{"spawn":{"provider":"gemini"},"providers":[{"id":"gemini","kind":"gateway","model":"gemini-2.5-pro","baseUrl":"http://localhost:4000","authTokenEnv":"MY_LITELLM_KEY"}]}' > "$CFG"
assert_eq "default provider id" "gemini" "$(cfg '.spawn.provider' '')"
assert_eq "provider model by index" "gemini-2.5-pro" "$(cfg '.providers[0].model' '')"
assert_eq "provider kind by index" "gateway" "$(cfg '.providers[0].kind' '')"
assert_eq "auth-token is a VAR NAME, not a key" "MY_LITELLM_KEY" "$(cfg '.providers[0].authTokenEnv' '')"
assert_eq "no literal key field present" "none" "$(cfg '.providers[0].authToken' 'none')"

finish
