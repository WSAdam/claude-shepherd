#!/usr/bin/env bash
# lib.test.sh - direct unit tests for cc-lib.sh helpers.
#
# cc_json_str is otherwise only exercised TRANSITIVELY, through the cc-status.sh
# jq-absent fallback (status.test.sh). A regression masked by the surrounding
# fallback formatting could slip through, so pin the function in isolation here.

. "$(dirname "$0")/lib.sh"

# cc-lib.sh runs `mkdir -p "$CC_DIR"` on source; point it at a temp dir so this
# stays side-effect-free (never touches ~/.claude/cc-status).
TMP="$(mktemp_dir)"
trap 'rm -rf "$TMP"' EXIT
export CC_STATUS_DIR="$TMP"
. "$ROOT/cc-lib.sh"

# Round-trip through jq is the strongest single assertion: it proves the output is
# valid JSON AND decodes byte-identically -- so no double-escaping crept in (a
# future reorder of the sed rules that double-escaped would fail the decode).
roundtrip() { # <label> <raw-input>
  local out enc dec
  out="$(cc_json_str "$2")"
  enc="$(printf '"%s"' "$out")"
  assert_eq "cc_json_str valid JSON: $1" "0" \
    "$(printf '%s' "$enc" | jq -e . >/dev/null 2>&1; echo $?)"
  dec="$(printf '%s' "$enc" | jq -r .)"
  assert_eq "cc_json_str round-trips: $1" "$2" "$dec"
}

roundtrip "plain"                               'hello world'
roundtrip "embedded double-quote"               'a"b'
roundtrip "embedded backslash"                  'a\b'
roundtrip "literal backslash-n (NOT a newline)" 'a\nb'
roundtrip "tab"                                 "$(printf 'tab\there')"
roundtrip "embedded newline"                    "$(printf 'l1\nl2')"
roundtrip "control char BEL 0x07"               "$(printf 'bell\007x')"
roundtrip "DEL 0x7f passes through raw"         "$(printf 'del\177x')"

# Pin the exact escapes the implementation promises, so a sed-rule reorder that
# silently changed them is caught directly (not only via the round-trip). The
# newline -> backslash-n case is covered by the embedded-newline round-trip above
# (a standalone trailing newline can't be pinned -- $() strips it).
q='"'; bs='\'
assert_eq "cc_json_str: double-quote -> backslash-quote" "${bs}${q}"   "$(cc_json_str "$q")"
assert_eq "cc_json_str: backslash -> double-backslash"   "${bs}${bs}"  "$(cc_json_str "$bs")"
assert_eq "cc_json_str: tab -> backslash-t"              "${bs}t"      "$(cc_json_str "$(printf '\t')")"
assert_eq "cc_json_str: BEL 0x07 -> u-escape"            "${bs}u0007"  "$(cc_json_str "$(printf '\007')")"

finish
